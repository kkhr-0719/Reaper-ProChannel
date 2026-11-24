-- src/core.lua
-- Reaper ProChannel (ReaPCh) — 纯逻辑层
-- 职责：0 号位 GUID 认亲、REAPER 7.06+ 容器编址计算、双区视图模型生成、移动/增删边界保护与设置持久化。
-- 约束：严禁调用任何 ReaImGui API，确保脱离 REAPER 宿主即可通过 lua tests/run.lua 运行单元测试。

local core = {}

core.VERSION = "0.2.0"
core.STRIP_DEFAULT_NAME = "◆ CHANNEL STRIP ◆"
core.EXT_SECTION = "REAPCH"
core.LEGACY_EXT_SECTION = "RPROCH"
core.TRACK_EXT_KEY = "P_EXT:REAPCH_STRIP_GUID"
core.LEGACY_TRACK_EXT_KEY = "P_EXT:RPROCH_STRIP_GUID"
core.CONTAINER_BASE = 0x2000000

core._reaper = nil
core._installed_fx_cache = nil
core._fxfolders_cache = nil
core._custom_fx_groups_cache = nil
core.CUSTOM_GROUPS_EXT_KEY = "custom_fx_groups"

--- 注入自定义或 Mock 的 reaper API 表（传入 nil 则回退至全局 _G.reaper，并重置已安装插件缓存）
function core.set_reaper(r)
  core._reaper = r
  core._installed_fx_cache = nil
  core._fxfolders_cache = nil
  core._custom_fx_groups_cache = nil
end

--- 获取当前生效的 reaper API 表
function core.get_reaper()
  local r = core._reaper or _G.reaper
  if not r then
    error("REAPER API table is not available")
  end
  return r
end

local function is_integer(n)
  return type(n) == "number" and math.floor(n) == n
end

local function begin_undo(r)
  if r and r.Undo_BeginBlock then
    r.Undo_BeginBlock()
  end
end

local function end_undo(r, desc)
  if r and r.Undo_EndBlock then
    r.Undo_EndBlock(desc or "ReaPCh Action", -1)
  end
end

--------------------------------------------------------------------------------
-- 1. ExtState 配置读写
--------------------------------------------------------------------------------

--- 读取持久化配置（向下兼容旧版 RPROCH 节名）
function core.load_settings()
  local r = core.get_reaper()
  local auto_snap = false
  local follow_theme = false
  if r.GetExtState then
    local raw_snap = r.GetExtState(core.EXT_SECTION, "auto_snap_slot0")
    if (not raw_snap or raw_snap == "") and core.LEGACY_EXT_SECTION then
      raw_snap = r.GetExtState(core.LEGACY_EXT_SECTION, "auto_snap_slot0")
    end
    local raw_theme = r.GetExtState(core.EXT_SECTION, "follow_host_theme")
    if (not raw_theme or raw_theme == "") and core.LEGACY_EXT_SECTION then
      raw_theme = r.GetExtState(core.LEGACY_EXT_SECTION, "follow_host_theme")
    end
    auto_snap = (raw_snap == "1")
    follow_theme = (raw_theme == "1")
  end
  return {
    auto_snap_slot0 = auto_snap,
    follow_host_theme = follow_theme,
  }
end

--- 保存单项布尔配置到 ExtState
function core.save_setting(key, bool_val)
  if type(key) ~= "string" or key == "" then
    return false
  end
  local r = core.get_reaper()
  if r.SetExtState then
    r.SetExtState(core.EXT_SECTION, key, bool_val and "1" or "0", true)
    return true
  end
  return false
end

--------------------------------------------------------------------------------
-- 2. REAPER 7.06+ FX Container 编址计算
--------------------------------------------------------------------------------

--- 构造目标容器内位置编码（用于移入或容器内排序）
--- 公式：0x2000000 + (child_pos_0based + 1) * (parent_fx_count + 1) + (container_idx_0based + 1)
function core.encode_container_item_index(container_idx_0based, child_pos_0based, parent_fx_count)
  if not is_integer(container_idx_0based) or container_idx_0based < 0 then
    error("container_idx_0based must be a non-negative integer")
  end
  if not is_integer(child_pos_0based) or child_pos_0based < 0 then
    error("child_pos_0based must be a non-negative integer")
  end
  if not is_integer(parent_fx_count) or parent_fx_count < 1 then
    error("parent_fx_count must be an integer >= 1")
  end
  if container_idx_0based >= parent_fx_count then
    error("container_idx_0based must be < parent_fx_count")
  end

  return core.CONTAINER_BASE
    + (child_pos_0based + 1) * (parent_fx_count + 1)
    + (container_idx_0based + 1)
end

--- 反解单层容器子项编码，返回 container_idx_0based, child_pos_0based
function core.decode_container_item_index(encoded_idx, parent_fx_count)
  if not is_integer(encoded_idx) or encoded_idx < core.CONTAINER_BASE then
    return nil, nil
  end
  if not is_integer(parent_fx_count) or parent_fx_count < 1 then
    return nil, nil
  end
  local offset = encoded_idx - core.CONTAINER_BASE
  local stride = parent_fx_count + 1
  local container_idx_1based = offset % stride
  local child_pos_1based = math.floor(offset / stride)
  if container_idx_1based < 1 or child_pos_1based < 1 then
    return nil, nil
  end
  return container_idx_1based - 1, child_pos_1based - 1
end

local function is_valid_fx_id(r, tr, fx_id)
  if not tr or not is_integer(fx_id) or fx_id < 0 then
    return false
  end
  local total = r.TrackFX_GetCount(tr) or 0
  if fx_id < core.CONTAINER_BASE then
    return fx_id < total
  end
  local c_idx, child_pos = core.decode_container_item_index(fx_id, total)
  if c_idx == nil or c_idx >= total or child_pos == nil or child_pos < 0 then
    return false
  end
  local ok, cnt_str = r.TrackFX_GetNamedConfigParm(tr, c_idx, "container_count")
  local cnt = (ok and tonumber(cnt_str)) or 0
  return child_pos < cnt
end

--- 获取指定 FX（含顶层常规插件与 0x2000000+ 容器子插件）的 REAPER 原生 Wet 参数索引
function core.get_fx_wet_param_index(tr, fx_id)
  local r = core.get_reaper()
  if not is_valid_fx_id(r, tr, fx_id) then
    return nil
  end
  if type(r.TrackFX_GetParamFromIdent) == "function" then
    local idx = r.TrackFX_GetParamFromIdent(tr, fx_id, ":wet")
    if is_integer(idx) and idx >= 0 then
      return idx
    end
  end
  if type(r.TrackFX_GetNumParams) == "function" and type(r.TrackFX_GetParamName) == "function" then
    local num = r.TrackFX_GetNumParams(tr, fx_id) or 0
    for i = num - 1, 0, -1 do
      local ok, pname = r.TrackFX_GetParamName(tr, fx_id, i, "")
      if ok and pname == "Wet" then
        return i
      end
    end
  end
  return nil
end

--- 读取指定 FX 的 Wet/Dry 干湿比（归一化为 0.0 .. 1.0）
--- @return boolean ok, number wet_0_to_1
function core.get_fx_wet(tr, fx_id)
  local r = core.get_reaper()
  if not is_valid_fx_id(r, tr, fx_id) then
    return false, 1.0
  end
  local param_idx = core.get_fx_wet_param_index(tr, fx_id)
  if param_idx == nil then
    return false, 1.0
  end
  local val = nil
  local minval, maxval = 0.0, 1.0
  if type(r.TrackFX_GetParam) == "function" then
    val, minval, maxval = r.TrackFX_GetParam(tr, fx_id, param_idx)
  elseif type(r.TrackFX_GetParamNormalized) == "function" then
    val = r.TrackFX_GetParamNormalized(tr, fx_id, param_idx)
  end
  if type(val) ~= "number" or val ~= val then
    return false, 1.0
  end
  if type(minval) == "number" and type(maxval) == "number" and maxval > minval then
    val = (val - minval) / (maxval - minval)
  end
  if val < 0.0 then
    val = 0.0
  elseif val > 1.0 then
    val = 1.0
  end
  return true, val
end

--- 设置指定 FX 的 Wet/Dry 干湿比（输入范围 0.0 .. 1.0，超出范围自动夹紧）
--- @param tr any MediaTrack
--- @param fx_id number 顶层索引或 0x2000000+ 容器子项编码
--- @param wet_0_to_1 number 目标干湿比 (0.0 .. 1.0)
--- @param record_undo boolean|nil 是否记录 Undo（默认 true；UI 连续拖拽过程中可传 false，松手时传 true）
--- @param pre_undo_wet_0_to_1 number|nil 可选：连续拖拽开始前的初始干湿比（用于在 Undo_BeginBlock 前恢复基线快照，确保 Ctrl+Z 一步退回拖拽前状态）
--- @return boolean ok, number|nil applied_wet
function core.set_fx_wet(tr, fx_id, wet_0_to_1, record_undo, pre_undo_wet_0_to_1)
  local r = core.get_reaper()
  if not is_valid_fx_id(r, tr, fx_id) or type(wet_0_to_1) ~= "number" then
    return false, nil
  end
  -- 防御 NaN
  if wet_0_to_1 ~= wet_0_to_1 then
    return false, nil
  end
  local param_idx = core.get_fx_wet_param_index(tr, fx_id)
  if param_idx == nil then
    return false, nil
  end
  local clamped = math.max(0.0, math.min(1.0, wet_0_to_1))
  local use_undo = (record_undo ~= false)

  local function apply_wet_param(val)
    if type(r.TrackFX_SetParam) == "function" then
      local ret = r.TrackFX_SetParam(tr, fx_id, param_idx, val)
      return (ret ~= false)
    elseif type(r.TrackFX_SetParamNormalized) == "function" then
      local ret = r.TrackFX_SetParamNormalized(tr, fx_id, param_idx, val)
      return (ret ~= false)
    end
    return false
  end

  if use_undo then
    if type(pre_undo_wet_0_to_1) == "number" and pre_undo_wet_0_to_1 == pre_undo_wet_0_to_1 then
      local pre_clamped = math.max(0.0, math.min(1.0, pre_undo_wet_0_to_1))
      apply_wet_param(pre_clamped)
    end
    begin_undo(r)
  end
  local ok = apply_wet_param(clamped)
  if use_undo then
    end_undo(r, "ReaPCh: Adjust FX Wet/Dry")
  end
  if not ok then
    return false, nil
  end
  return true, clamped
end

--------------------------------------------------------------------------------
-- 3. 0 号位容器“GUID 认亲”与初始化
--------------------------------------------------------------------------------

--- 在轨道顶层查找已绑定的 0 号位 Strip 容器（严禁硬编码 index == 0；向下兼容旧版 P_EXT:RPROCH_STRIP_GUID）
--- @param tr any MediaTrack
--- @return number|nil container_idx_0based, string|nil saved_guid, boolean is_stale_guid
function core.find_strip_container(tr)
  if not tr then
    return nil, nil, false
  end
  local r = core.get_reaper()
  local ok, saved_guid = r.GetSetMediaTrackInfo_String(tr, core.TRACK_EXT_KEY, "", false)
  if (not ok or not saved_guid or saved_guid == "") and core.LEGACY_TRACK_EXT_KEY then
    ok, saved_guid = r.GetSetMediaTrackInfo_String(tr, core.LEGACY_TRACK_EXT_KEY, "", false)
  end
  if not ok or not saved_guid or saved_guid == "" then
    return nil, nil, false
  end

  local fx_count = r.TrackFX_GetCount(tr) or 0
  for i = 0, fx_count - 1 do
    local fx_guid = r.TrackFX_GetFXGUID(tr, i)
    if fx_guid and fx_guid == saved_guid then
      return i, saved_guid, false
    end
  end

  -- 容器已被用户在原生界面手动删除，优雅降级为未初始化状态
  return nil, saved_guid, true
end

local function create_strip_container_internal(r, tr)
  local existing_idx, existing_guid = core.find_strip_container(tr)
  if existing_idx ~= nil then
    return true, existing_idx, existing_guid
  end

  -- 1. 在顶层最前端 (index 0) 创建 Container
  local idx = r.TrackFX_AddByName(tr, "Container", false, -1000)
  if not idx or idx < 0 then
    return false, nil, nil
  end

  -- 2. 重命名容器为 ◆ CHANNEL STRIP ◆
  r.TrackFX_SetNamedConfigParm(tr, idx, "renamed_name", core.STRIP_DEFAULT_NAME)

  -- 3. 读取容器 GUID
  local guid = r.TrackFX_GetFXGUID(tr, idx)
  if not guid or guid == "" then
    return false, nil, nil
  end

  -- 4. 持久化绑定至该轨道 P_EXT:REAPCH_STRIP_GUID
  r.GetSetMediaTrackInfo_String(tr, core.TRACK_EXT_KEY, guid, true)
  return true, idx, guid
end

--- 按需初始化 0 号位 Channel Strip 容器
function core.init_strip_container(tr)
  if not tr then
    return false, nil, nil
  end
  local r = core.get_reaper()
  local existing_idx, existing_guid = core.find_strip_container(tr)
  if existing_idx ~= nil then
    return true, existing_idx, existing_guid
  end

  begin_undo(r)
  local ok, idx, guid = create_strip_container_internal(r, tr)
  end_undo(r, ok and "ReaPCh: Initialize Channel Strip" or "ReaPCh: Failed to Initialize Channel Strip")
  return ok, idx, guid
end

--- 读取 0 号位容器内部的所有子插件列表
function core.get_strip_children(tr, container_idx)
  local children = {}
  if not tr or not is_integer(container_idx) or container_idx < 0 then
    return children
  end
  local r = core.get_reaper()
  local ok, cnt_str = r.TrackFX_GetNamedConfigParm(tr, container_idx, "container_count")
  local cnt = (ok and tonumber(cnt_str)) or 0
  if cnt <= 0 then
    return children
  end

  local parent_fx_count = r.TrackFX_GetCount(tr) or 1
  for i = 0, cnt - 1 do
    local ok_item, id_str = r.TrackFX_GetNamedConfigParm(tr, container_idx, "container_item." .. i)
    local fx_id = ok_item and tonumber(id_str)
    if not fx_id then
      fx_id = core.encode_container_item_index(container_idx, i, parent_fx_count)
    end
    local _, name = r.TrackFX_GetFXName(tr, fx_id, "")
    local enabled = r.TrackFX_GetEnabled(tr, fx_id)
    local guid = r.TrackFX_GetFXGUID(tr, fx_id)
    local is_open = false
    if r.TrackFX_GetOpen then
      is_open = r.TrackFX_GetOpen(tr, fx_id) and true or false
    end
    local _, wet_val = core.get_fx_wet(tr, fx_id)
    local wet_num = (type(wet_val) == "number") and wet_val or 1.0
    children[#children + 1] = {
      slot = i + 1,
      child_index = i,
      fx_id = fx_id,
      name = name or "",
      enabled = (enabled ~= false),
      guid = guid or "",
      is_open = is_open,
      wet = wet_num,
      wet_percent = math.floor(wet_num * 100 + 0.5),
    }
  end
  return children
end

--- 向 0 号位容器末尾添加子插件（若容器未初始化则自动先建容器再置入）
function core.add_fx_to_strip(tr, fx_ident)
  if not tr or type(fx_ident) ~= "string" or fx_ident == "" then
    return false, nil, nil
  end
  local r = core.get_reaper()
  begin_undo(r)

  local container_idx = core.find_strip_container(tr)
  local _, prev_primary_guid = r.GetSetMediaTrackInfo_String(tr, core.TRACK_EXT_KEY, "", false)
  local created_container_now = false
  if container_idx == nil then
    local ok_init
    ok_init, container_idx = create_strip_container_internal(r, tr)
    if not ok_init or container_idx == nil then
      end_undo(r, "ReaPCh: Failed to Add FX to Strip")
      return false, nil, nil
    end
    created_container_now = true
  end

  -- 1. 先添加至轨道顶层末尾
  local new_idx = r.TrackFX_AddByName(tr, fx_ident, false, -1)
  if not new_idx or new_idx < 0 then
    if created_container_now then
      local cur_c_idx = core.find_strip_container(tr)
      if cur_c_idx ~= nil then
        r.TrackFX_Delete(tr, cur_c_idx)
      end
      r.GetSetMediaTrackInfo_String(tr, core.TRACK_EXT_KEY, prev_primary_guid or "", true)
    end
    end_undo(r, "ReaPCh: Failed to Add FX to Strip")
    return false, nil, nil
  end

  -- 重新确认容器当前顶层索引
  container_idx = core.find_strip_container(tr)
  if container_idx == nil then
    end_undo(r, "ReaPCh: Failed to Add FX to Strip")
    return false, nil, nil
  end

  -- 2. 重新获取实时 parent_fx_count 与当前 container_count
  local parent_fx_count = r.TrackFX_GetCount(tr)
  local ok_cnt, cnt_str = r.TrackFX_GetNamedConfigParm(tr, container_idx, "container_count")
  local child_pos_0based = (ok_cnt and tonumber(cnt_str)) or 0

  -- 3. 计算容器末尾的 encoded_idx
  local move_target_encoded_idx = core.encode_container_item_index(
    container_idx,
    child_pos_0based,
    parent_fx_count
  )

  -- 4. 移入容器
  r.TrackFX_CopyToTrack(tr, new_idx, tr, move_target_encoded_idx, true)

  end_undo(r, "ReaPCh: Add FX to Channel Strip")

  -- 移入完成后顶层 FX 总数减少 1，计算子项当前最新 fx_id
  local final_container_idx = core.find_strip_container(tr) or container_idx
  local ok_item, id_str = r.TrackFX_GetNamedConfigParm(
    tr,
    final_container_idx,
    "container_item." .. child_pos_0based
  )
  local final_fx_id = (ok_item and tonumber(id_str))
    or core.encode_container_item_index(final_container_idx, child_pos_0based, r.TrackFX_GetCount(tr))

  return true, final_fx_id, move_target_encoded_idx
end

--- 0 号位容器内部子插件排序（1-based 槽位：1 .. container_count）
function core.move_strip_fx(tr, from_slot_1based, to_slot_1based)
  if not tr or not is_integer(from_slot_1based) or not is_integer(to_slot_1based) then
    return false, "invalid slot type"
  end
  local r = core.get_reaper()
  local container_idx = core.find_strip_container(tr)
  if container_idx == nil then
    return false, "strip not initialized"
  end

  local ok_cnt, cnt_str = r.TrackFX_GetNamedConfigParm(tr, container_idx, "container_count")
  local cnt = (ok_cnt and tonumber(cnt_str)) or 0
  if from_slot_1based < 1 or from_slot_1based > cnt or to_slot_1based < 1 or to_slot_1based > cnt then
    return false, "strip slot out of bounds"
  end
  if from_slot_1based == to_slot_1based then
    return true
  end

  local from_0 = from_slot_1based - 1
  local to_0 = to_slot_1based - 1
  local parent_fx_count = r.TrackFX_GetCount(tr)

  local ok_src, src_str = r.TrackFX_GetNamedConfigParm(tr, container_idx, "container_item." .. from_0)
  local src_fx_id = (ok_src and tonumber(src_str))
    or core.encode_container_item_index(container_idx, from_0, parent_fx_count)
  local dst_fx_id = core.encode_container_item_index(container_idx, to_0, parent_fx_count)

  begin_undo(r)
  r.TrackFX_CopyToTrack(tr, src_fx_id, tr, dst_fx_id, true)
  end_undo(r, "ReaPCh: Reorder Strip FX")
  return true
end

--- 从 0 号位容器移除指定子插件（1-based 槽位：1 .. container_count）
function core.remove_strip_fx(tr, slot_1based)
  if not tr or not is_integer(slot_1based) then
    return false, "invalid slot type"
  end
  local r = core.get_reaper()
  local container_idx = core.find_strip_container(tr)
  if container_idx == nil then
    return false, "strip not initialized"
  end

  local ok_cnt, cnt_str = r.TrackFX_GetNamedConfigParm(tr, container_idx, "container_count")
  local cnt = (ok_cnt and tonumber(cnt_str)) or 0
  if slot_1based < 1 or slot_1based > cnt then
    return false, "strip slot out of bounds"
  end

  local child_0 = slot_1based - 1
  local parent_fx_count = r.TrackFX_GetCount(tr)
  local ok_item, id_str = r.TrackFX_GetNamedConfigParm(tr, container_idx, "container_item." .. child_0)
  local fx_id = (ok_item and tonumber(id_str))
    or core.encode_container_item_index(container_idx, child_0, parent_fx_count)

  begin_undo(r)
  r.TrackFX_Delete(tr, fx_id)
  end_undo(r, "ReaPCh: Remove Strip FX")
  return true
end

--- 将偏离 index 0 的 0 号位容器一键归位至顶层最前端 (index 0)
--- @return boolean ok, boolean moved
function core.snap_strip_to_top(tr)
  if not tr then
    return false, false
  end
  local r = core.get_reaper()
  local strip_idx = core.find_strip_container(tr)
  if strip_idx == nil then
    return false, false
  end
  if strip_idx == 0 then
    return true, false
  end

  begin_undo(r)
  r.TrackFX_CopyToTrack(tr, strip_idx, tr, 0, true)
  end_undo(r, "ReaPCh: Snap Channel Strip to Slot 0")
  return true, true
end

--------------------------------------------------------------------------------
-- 4. 下半区常规 FX 列表、视觉索引映射与边界拦截
--------------------------------------------------------------------------------

--- 构建下半区常规 FX 列表（隐藏 0 号位容器本体，视觉编号从 1 递增）
function core.get_normal_fx_list(tr, strip_idx_override)
  local normal_fx = {}
  if not tr then
    return normal_fx
  end
  local r = core.get_reaper()
  local strip_idx = strip_idx_override
  if strip_idx == nil then
    strip_idx = core.find_strip_container(tr)
  end

  local total = r.TrackFX_GetCount(tr) or 0
  for i = 0, total - 1 do
    if i ~= strip_idx then
      local visual_slot = #normal_fx + 1
      local _, name = r.TrackFX_GetFXName(tr, i, "")
      local enabled = r.TrackFX_GetEnabled(tr, i)
      local guid = r.TrackFX_GetFXGUID(tr, i)
      local is_open = false
      if r.TrackFX_GetOpen then
        is_open = r.TrackFX_GetOpen(tr, i) and true or false
      end
      local _, wet_val = core.get_fx_wet(tr, i)
      local wet_num = (type(wet_val) == "number") and wet_val or 1.0
      normal_fx[visual_slot] = {
        visual_slot = visual_slot,
        top_index = i,
        fx_id = i,
        name = name or "",
        enabled = (enabled ~= false),
        guid = guid or "",
        is_open = is_open,
        wet = wet_num,
        wet_percent = math.floor(wet_num * 100 + 0.5),
      }
    end
  end
  return normal_fx
end

--- 将下半区视觉槽位 (1..N) 映射为 REAPER 顶层真实 0-based 索引
function core.visual_slot_to_top_index(tr, visual_slot)
  if not tr or not is_integer(visual_slot) or visual_slot < 1 then
    return nil, "visual_slot out of bounds"
  end
  local strip_idx = core.find_strip_container(tr)
  local normal_fx = core.get_normal_fx_list(tr, strip_idx)
  local item = normal_fx[visual_slot]
  if not item then
    return nil, "visual_slot out of bounds"
  end
  if strip_idx ~= nil and item.top_index == strip_idx then
    return nil, "cannot target strip container"
  end
  return item.top_index, nil
end

--- 向下半区添加或插入常规 FX（支持按视觉槽位 1..N+1 插入，严格防止覆盖或挤占 0 号位容器）
--- @param tr any MediaTrack
--- @param fx_ident string 插件标识符
--- @param target_visual_slot number|nil 可选目标视觉槽位（1..N+1；省略则追加到下半区末尾）
--- @return boolean ok, number|nil top_index, string|nil err
function core.add_normal_fx(tr, fx_ident, target_visual_slot)
  if not tr or type(fx_ident) ~= "string" or fx_ident == "" then
    return false, nil, "invalid arguments"
  end
  local r = core.get_reaper()
  local strip_idx, strip_guid = core.find_strip_container(tr)
  local normal_fx = core.get_normal_fx_list(tr, strip_idx)
  local count = #normal_fx

  local instantiate = -1
  if target_visual_slot ~= nil then
    if not is_integer(target_visual_slot) or target_visual_slot < 1 or target_visual_slot > count + 1 then
      return false, nil, "visual_slot out of bounds"
    end
    if target_visual_slot <= count then
      local target_item = normal_fx[target_visual_slot]
      if not target_item then
        return false, nil, "visual_slot out of bounds"
      end
      if (strip_idx ~= nil and target_item.top_index == strip_idx)
        or (strip_guid and target_item.guid == strip_guid) then
        return false, nil, "cannot overwrite 0-slot strip container"
      end
      instantiate = -1000 - target_item.top_index
    end
  end

  begin_undo(r)
  local new_top_idx = r.TrackFX_AddByName(tr, fx_ident, false, instantiate)
  if not new_top_idx or new_top_idx < 0 then
    end_undo(r, "ReaPCh: Failed to Add Normal FX")
    return false, nil, "failed to instantiate FX"
  end
  end_undo(r, "ReaPCh: Add Normal FX")
  return true, new_top_idx, nil
end

--- 下半区常规 FX 拖拽排序（基于视觉槽位 1..N，严格保护 0 号位容器不被越界覆盖）
function core.move_normal_fx(tr, from_visual_slot, to_visual_slot)
  if not tr or not is_integer(from_visual_slot) or not is_integer(to_visual_slot) then
    return false, "invalid visual slot"
  end
  local r = core.get_reaper()
  local strip_idx, strip_guid = core.find_strip_container(tr)
  local normal_fx = core.get_normal_fx_list(tr, strip_idx)
  local count = #normal_fx

  if from_visual_slot < 1 or from_visual_slot > count or to_visual_slot < 1 or to_visual_slot > count then
    return false, "visual_slot out of bounds"
  end
  if from_visual_slot == to_visual_slot then
    return true
  end

  local from_item = normal_fx[from_visual_slot]
  local to_item = normal_fx[to_visual_slot]
  if not from_item or not to_item then
    return false, "visual_slot out of bounds"
  end
  if strip_idx ~= nil and (from_item.top_index == strip_idx or to_item.top_index == strip_idx) then
    return false, "cannot move or overwrite 0-slot strip container"
  end
  if strip_guid and (from_item.guid == strip_guid or to_item.guid == strip_guid) then
    return false, "cannot move or overwrite 0-slot strip container"
  end

  begin_undo(r)
  r.TrackFX_CopyToTrack(tr, from_item.top_index, tr, to_item.top_index, true)
  end_undo(r, "ReaPCh: Reorder Normal FX")
  return true
end

--- 下半区删除常规 FX（按视觉槽位 1..N，严格拦截越界与 0 号位容器）
function core.delete_normal_fx(tr, visual_slot)
  if not tr or not is_integer(visual_slot) or visual_slot < 1 then
    return false, "visual_slot out of bounds"
  end
  local r = core.get_reaper()
  local strip_idx, strip_guid = core.find_strip_container(tr)
  local normal_fx = core.get_normal_fx_list(tr, strip_idx)
  local item = normal_fx[visual_slot]
  if not item then
    return false, "visual_slot out of bounds"
  end
  if (strip_idx ~= nil and item.top_index == strip_idx) or (strip_guid and item.guid == strip_guid) then
    return false, "cannot delete 0-slot strip container"
  end

  begin_undo(r)
  r.TrackFX_Delete(tr, item.top_index)
  end_undo(r, "ReaPCh: Delete Normal FX")
  return true
end

--- 按顶层 0-based 索引删除常规 FX（带 0 号位容器硬拦截保护）
function core.delete_top_fx_guarded(tr, top_index)
  if not tr or not is_integer(top_index) or top_index < 0 then
    return false, "top_index out of bounds"
  end
  local r = core.get_reaper()
  local total = r.TrackFX_GetCount(tr) or 0
  if top_index >= total then
    return false, "top_index out of bounds"
  end
  local strip_idx, strip_guid = core.find_strip_container(tr)
  local target_guid = r.TrackFX_GetFXGUID(tr, top_index)
  if (strip_idx ~= nil and top_index == strip_idx) or (strip_guid and target_guid == strip_guid) then
    return false, "cannot delete 0-slot strip container"
  end

  begin_undo(r)
  r.TrackFX_Delete(tr, top_index)
  end_undo(r, "ReaPCh: Delete Normal FX")
  return true
end

--- 将下半区常规 FX 跨区移入上半区 0 号位 Channel Strip 容器（若 Strip 未初始化则自动建容器并移入）
--- @param tr any MediaTrack
--- @param from_visual_slot number 下半区源视觉槽位 (1..N)
--- @param to_strip_slot_1based number|nil 目标容器内 1-based 槽位 (1..M+1；省略则追加至容器末尾)
--- @return boolean ok, string|nil err
function core.move_normal_fx_to_strip(tr, from_visual_slot, to_strip_slot_1based)
  if not tr or not is_integer(from_visual_slot) then
    return false, "invalid visual slot"
  end
  if to_strip_slot_1based ~= nil and not is_integer(to_strip_slot_1based) then
    return false, "invalid strip slot"
  end

  local r = core.get_reaper()
  local strip_idx, strip_guid = core.find_strip_container(tr)
  local normal_fx = core.get_normal_fx_list(tr, strip_idx)
  local normal_count = #normal_fx

  if from_visual_slot < 1 or from_visual_slot > normal_count then
    return false, "visual_slot out of bounds"
  end

  local from_item = normal_fx[from_visual_slot]
  if not from_item then
    return false, "visual_slot out of bounds"
  end
  if (strip_idx ~= nil and from_item.top_index == strip_idx)
    or (strip_guid and from_item.guid == strip_guid) then
    return false, "cannot move 0-slot strip container into itself"
  end

  if strip_idx == nil then
    if to_strip_slot_1based ~= nil and to_strip_slot_1based ~= 1 then
      return false, "strip slot out of bounds"
    end
  else
    local ok_cnt, cnt_str = r.TrackFX_GetNamedConfigParm(tr, strip_idx, "container_count")
    local cnt = (ok_cnt and tonumber(cnt_str)) or 0
    local target_1 = to_strip_slot_1based or (cnt + 1)
    if target_1 < 1 or target_1 > cnt + 1 then
      return false, "strip slot out of bounds"
    end
  end

  begin_undo(r)

  if strip_idx == nil then
    local ok_init
    ok_init, strip_idx, strip_guid = create_strip_container_internal(r, tr)
    if not ok_init or strip_idx == nil then
      end_undo(r, "ReaPCh: Failed to Move Normal FX to Strip")
      return false, "failed to initialize strip container"
    end
    normal_fx = core.get_normal_fx_list(tr, strip_idx)
    from_item = normal_fx[from_visual_slot]
    if not from_item then
      end_undo(r, "ReaPCh: Failed to Move Normal FX to Strip")
      return false, "visual_slot out of bounds"
    end
  end

  local ok_cnt, cnt_str = r.TrackFX_GetNamedConfigParm(tr, strip_idx, "container_count")
  local cnt = (ok_cnt and tonumber(cnt_str)) or 0
  local target_slot_1 = to_strip_slot_1based or (cnt + 1)
  local child_pos_0based = target_slot_1 - 1
  local parent_fx_count = r.TrackFX_GetCount(tr)

  local dst_encoded_idx = core.encode_container_item_index(
    strip_idx,
    child_pos_0based,
    parent_fx_count
  )

  r.TrackFX_CopyToTrack(tr, from_item.top_index, tr, dst_encoded_idx, true)
  end_undo(r, "ReaPCh: Move Normal FX to Channel Strip")
  return true
end

--- 将上半区 0 号位 Channel Strip 子插件跨区移出至下半区常规 FX 槽（严格保护 0 号位容器本体不被覆盖或挤占）
--- @param tr any MediaTrack
--- @param from_strip_slot_1based number 上半区源子项 1-based 槽位 (1..M)
--- @param to_visual_slot number|nil 下半区目标视觉槽位 (1..N+1；省略则追加至下半区末尾)
--- @return boolean ok, string|nil err
function core.move_strip_fx_to_normal(tr, from_strip_slot_1based, to_visual_slot)
  if not tr or not is_integer(from_strip_slot_1based) then
    return false, "invalid strip slot"
  end
  if to_visual_slot ~= nil and not is_integer(to_visual_slot) then
    return false, "invalid visual slot"
  end

  local r = core.get_reaper()
  local strip_idx, strip_guid = core.find_strip_container(tr)
  if strip_idx == nil then
    return false, "strip not initialized"
  end

  local ok_cnt, cnt_str = r.TrackFX_GetNamedConfigParm(tr, strip_idx, "container_count")
  local cnt = (ok_cnt and tonumber(cnt_str)) or 0
  if from_strip_slot_1based < 1 or from_strip_slot_1based > cnt then
    return false, "strip slot out of bounds"
  end

  local normal_fx = core.get_normal_fx_list(tr, strip_idx)
  local normal_count = #normal_fx
  local target_visual = to_visual_slot or (normal_count + 1)
  if target_visual < 1 or target_visual > normal_count + 1 then
    return false, "visual_slot out of bounds"
  end

  local parent_fx_count = r.TrackFX_GetCount(tr) or 1
  local child_0 = from_strip_slot_1based - 1
  local ok_item, id_str = r.TrackFX_GetNamedConfigParm(tr, strip_idx, "container_item." .. child_0)
  local src_fx_id = (ok_item and tonumber(id_str))
    or core.encode_container_item_index(strip_idx, child_0, parent_fx_count)

  local dst_top_idx = parent_fx_count
  if target_visual <= normal_count then
    local target_item = normal_fx[target_visual]
    if not target_item then
      return false, "visual_slot out of bounds"
    end
    if target_item.top_index == strip_idx or (strip_guid and target_item.guid == strip_guid) then
      return false, "cannot overwrite 0-slot strip container"
    end
    dst_top_idx = target_item.top_index
  end

  begin_undo(r)
  r.TrackFX_CopyToTrack(tr, src_fx_id, tr, dst_top_idx, true)
  end_undo(r, "ReaPCh: Move Strip FX to Normal Slot")
  return true
end

--------------------------------------------------------------------------------
-- 5. 通用交互动作（Bypass / 悬浮窗切换）
--------------------------------------------------------------------------------

--- 切换或设置 0 号位容器整区总 Bypass（enabled = true 为启用，false 为旁通）
function core.set_strip_enabled(tr, enabled)
  if not tr then
    return false
  end
  local r = core.get_reaper()
  local strip_idx = core.find_strip_container(tr)
  if strip_idx == nil then
    return false
  end
  local target = enabled
  if target == nil then
    target = not r.TrackFX_GetEnabled(tr, strip_idx)
  end
  begin_undo(r)
  r.TrackFX_SetEnabled(tr, strip_idx, target and true or false)
  end_undo(r, "ReaPCh: Toggle Channel Strip Bypass")
  return true, target
end

--- 切换或设置单个插件（容器子项或顶层常规插件）启用状态
function core.set_fx_enabled(tr, fx_id, enabled)
  local r = core.get_reaper()
  if not is_valid_fx_id(r, tr, fx_id) then
    return false
  end
  local target = enabled
  if target == nil then
    target = not r.TrackFX_GetEnabled(tr, fx_id)
  end
  begin_undo(r)
  r.TrackFX_SetEnabled(tr, fx_id, target and true or false)
  end_undo(r, "ReaPCh: Toggle FX Bypass")
  return true, target
end

--- 点击插件名称切换原生 VST 悬浮窗显示/隐藏（showflag: 3 = show floating, 2 = hide floating）
function core.toggle_fx_floating_window(tr, fx_id)
  local r = core.get_reaper()
  if not is_valid_fx_id(r, tr, fx_id) then
    return false
  end
  local is_open = false
  if r.TrackFX_GetOpen then
    is_open = r.TrackFX_GetOpen(tr, fx_id) and true or false
  elseif r.TrackFX_GetFloatingWindow then
    is_open = (r.TrackFX_GetFloatingWindow(tr, fx_id) ~= nil)
  end
  local show_flag = is_open and 2 or 3
  if r.TrackFX_Show then
    r.TrackFX_Show(tr, fx_id, show_flag)
  end
  return true, not is_open
end

--------------------------------------------------------------------------------
-- 6. 已安装插件枚举缓存、乐器(Synth)识别、REAPER 原生与自定义分组、多关键词搜索过滤
--------------------------------------------------------------------------------

local INSTRUMENT_FORMATS = {
  VSTI = true,
  VST3I = true,
  CLAPI = true,
  AUI = true,
  LV2I = true,
  DXI = true,
}

-- REAPER 在扫描支持 Tempo Sync / MIDI 端口的 DirectX 音频效果器时会将其标为 DXi: 前缀；
-- 将已知的 4 个 Sonitus / Cakewalk 音频效果器列入硬编码豁免名单，确保默认隐藏乐器时仍作为效果器正常显示。
local DXI_EFFECT_EXCEPTIONS = {
  ["sonitus:fx delay"] = true,
  ["cakewalk tempo delay"] = true,
  ["cakewalk classic phaser"] = true,
  ["cakewalk modfilter"] = true,
}

local function trim_str(s)
  if type(s) ~= "string" then
    return ""
  end
  return s:match("^%s*(.-)%s*$") or ""
end

local function unquote_str(s)
  local t = trim_str(s)
  if (#t >= 2 and t:sub(1, 1) == '"' and t:sub(-1) == '"')
    or (#t >= 2 and t:sub(1, 1) == "'" and t:sub(-1) == "'") then
    return t:sub(2, -2)
  end
  return t
end

--- 判断给定插件格式前缀是否属于合成器/虚拟乐器（VSTi / VST3i / CLAPi / AUi / LV2i / DXi）
function core.is_instrument_format(fmt)
  if type(fmt) ~= "string" or fmt == "" then
    return false
  end
  return INSTRUMENT_FORMATS[fmt:upper()] == true
end

--- 判断给定插件名称或插件项是否属于被 REAPER 标为 DXi: 的已知音频效果器豁免例外
function core.is_dxi_effect_exception(name_or_item)
  local raw_name = ""
  local short_name = ""
  if type(name_or_item) == "table" then
    raw_name = tostring(name_or_item.name or "")
    short_name = tostring(name_or_item.short_name or "")
  elseif type(name_or_item) == "string" then
    raw_name = name_or_item
  end

  if short_name ~= "" then
    local low_short = trim_str(short_name):lower()
    if DXI_EFFECT_EXCEPTIONS[low_short] then
      return true
    end
  end

  if raw_name ~= "" then
    local low_raw = trim_str(raw_name):lower()
    if DXI_EFFECT_EXCEPTIONS[low_raw] then
      return true
    end
    local no_prefix = trim_str(raw_name:gsub("^[%w_]+:%s+", "")):lower()
    if DXI_EFFECT_EXCEPTIONS[no_prefix] then
      return true
    end
    local _, parsed_short = core.parse_fx_display_name(raw_name, "")
    if parsed_short and parsed_short ~= "" then
      local low_parsed = trim_str(parsed_short):lower()
      if DXI_EFFECT_EXCEPTIONS[low_parsed] then
        return true
      end
    end
  end

  return false
end

--- 判断插件项或插件名称/分类标签是否属于合成器/虚拟乐器
--- @param name_or_item string|table 插件显示名称或已解析的插件表
--- @param category_tag string|nil 可选的 reaper-fxtags.ini 分类标签
--- @return boolean is_instrument
function core.is_instrument_fx(name_or_item, category_tag)
  local fmt = ""
  local tag = category_tag
  if type(name_or_item) == "table" then
    if name_or_item.is_instrument ~= nil and tag == nil then
      return name_or_item.is_instrument and true or false
    end
    fmt = tostring(name_or_item.format or "")
    if fmt == "" and type(name_or_item.name) == "string" then
      fmt = name_or_item.name:match("^([%w_]+):%s+") or ""
    end
    tag = tag or name_or_item.tag_category
  elseif type(name_or_item) == "string" then
    fmt = name_or_item:match("^([%w_]+):%s+") or ""
  end

  if core.is_dxi_effect_exception(name_or_item) then
    return false
  end

  if core.is_instrument_format(fmt) then
    return true
  end

  if type(tag) == "string" and tag ~= "" then
    for seg in tag:lower():gmatch("[^|,/]+") do
      local clean_seg = trim_str(seg)
      if clean_seg == "instrument"
        or clean_seg == "instruments"
        or clean_seg == "synth"
        or clean_seg == "synthesizer"
        or clean_seg == "sampler"
        or clean_seg:match("^instrument%s")
        or clean_seg:match("^instruments%s")
        or clean_seg:match("^synth%s")
        or clean_seg:match("^synthesizer%s") then
        return true
      end
    end
  end

  return false
end

local function ident_lookup_keys(ident, name)
  local keys = {}
  local seen = {}
  local function add_key(k)
    if type(k) == "string" then
      local clean = trim_str(k):lower()
      if clean ~= "" and not seen[clean] then
        seen[clean] = true
        keys[#keys + 1] = clean
      end
    end
  end
  local function add_key_variants(k)
    if type(k) ~= "string" or k == "" then
      return
    end
    add_key(k)
    add_key(k:gsub("%s+", "_"))
    add_key(k:gsub("[%s%-]+", "_"))
  end

  if type(ident) == "string" and ident ~= "" then
    add_key_variants(ident)
    local no_sub = ident:match("^([^<@]+)")
    if no_sub then
      add_key_variants(no_sub)
    end
    local base = ident:match("([^/\\]+)$")
    if base then
      add_key_variants(base)
      local base_no_sub = base:match("^([^<@]+)") or base
      add_key_variants(base_no_sub)
      local stem = base_no_sub:match("^(.+)%.[^%.]+$")
      if stem then
        add_key_variants(stem)
      end
    end
  end

  if type(name) == "string" and name ~= "" then
    add_key(name)
    local no_prefix = name:gsub("^[%w_]+:%s+", "")
    add_key(no_prefix)
    local _, short_name = core.parse_fx_display_name(name, ident)
    if short_name and short_name ~= "" then
      add_key(short_name)
    end
  end

  return keys
end

--- 从插件显示名称与标识符中提取格式前缀 (format)、短名称 (short_name) 与厂商 (developer)
function core.parse_fx_display_name(display_name, ident)
  local raw = (type(display_name) == "string") and display_name or ""
  local raw_ident = (type(ident) == "string") and ident or ""
  local fmt, rest = raw:match("^([%w_]+):%s+(.+)$")
  if not fmt then
    fmt = ""
    rest = raw
  end

  local working = trim_str(rest)
  -- 剥离末尾通道数描述，如 (8ch)、(64 out)、(mono)、(stereo)、(2->4ch)
  while true do
    local stripped = working:match("^(.-)%s*%([%d%s%-/>]*ch%)$")
      or working:match("^(.-)%s*%([%d%s%-/>]*out%)$")
      or working:match("^(.-)%s*%([%d%s%-/>]*in%)$")
      or working:match("^(.-)%s*%(mono%)$")
      or working:match("^(.-)%s*%(stereo%)$")
    if stripped and stripped ~= "" then
      working = trim_str(stripped)
    else
      break
    end
  end

  local developer = ""
  local short_name = working

  -- 提取末尾括号 (Developer) 或方括号 [Developer]
  local body_paren, dev_paren = working:match("^(.-)%s*%(([^%(%)]+)%)$")
  if body_paren and trim_str(body_paren) ~= "" and dev_paren then
    local dev_candidate = trim_str(dev_paren)
    -- 排除类似 (100%) 或纯数字的括号后缀
    if not dev_candidate:match("^[%d%.%%%+%-]+$") then
      short_name = trim_str(body_paren)
      developer = dev_candidate
    end
  end

  if developer == "" then
    local body_bracket, dev_bracket = working:match("^(.-)%s*%[([^%[%]]+)%]$")
    if body_bracket and trim_str(body_bracket) ~= "" and dev_bracket then
      local dev_candidate = trim_str(dev_bracket)
      if not dev_candidate:match("^[%d%.%%%+%-]+$") then
        short_name = trim_str(body_bracket)
        developer = dev_candidate
      end
    end
  end

  if developer == "" and fmt:upper() == "JS" and raw_ident ~= "" then
    local js_folder = raw_ident:match("^([^/\\]+)[/\\]")
    if js_folder and js_folder ~= "" then
      developer = "JS (" .. js_folder .. ")"
    else
      developer = "Cockos (JS)"
    end
  end

  return fmt, (short_name ~= "" and short_name or raw), developer
end

--- 解析 REAPER reaper-fxtags.ini 内容，提取插件的 [category] 与 [developer] 映射表
function core.parse_fxtags_ini(content)
  local result = {
    categories = {},
    developers = {},
  }
  if type(content) ~= "string" or content == "" then
    return result
  end

  local function store_tag_entry(tbl, raw_key, val)
    for _, k in ipairs(ident_lookup_keys(raw_key, "")) do
      if tbl[k] == nil then
        tbl[k] = val
      end
    end
    tbl[raw_key] = val
  end

  local current_sec = ""
  for line in content:gmatch("[^\r\n]+") do
    local trimmed = trim_str(line)
    if trimmed ~= "" and not trimmed:match("^[;#]") then
      local sec = trimmed:match("^%[([^%]]+)%]$")
      if sec then
        current_sec = trim_str(sec):lower()
      else
        local k, v = trimmed:match("^([^=]+)=(.*)$")
        if k and v then
          local key = unquote_str(k):lower()
          local val = unquote_str(v)
          if key ~= "" and val ~= "" then
            if current_sec == "category" or current_sec == "categories" then
              store_tag_entry(result.categories, key, val)
            elseif current_sec == "developer" or current_sec == "developers" then
              store_tag_entry(result.developers, key, val)
            end
          end
        end
      end
    end
  end
  return result
end

--- 解析 REAPER reaper-fxfolders.ini 内容，支持标准 [Folders]+[Folder<id>] 结构与 Type=16777216 智能文件夹过滤词
function core.parse_fxfolders_ini(content)
  local folders = {}
  if type(content) ~= "string" or content == "" then
    return folders
  end

  local sections = {}
  local sec_order = {}
  local current_sec = nil

  for line in content:gmatch("[^\r\n]+") do
    local trimmed = trim_str(line)
    if trimmed ~= "" and not trimmed:match("^[;#]") then
      local sec_name = trimmed:match("^%[([^%]]+)%]$")
      if sec_name then
        current_sec = trim_str(sec_name)
        local low = current_sec:lower()
        if not sections[low] then
          sections[low] = { raw_name = current_sec, kv = {}, ordered_values = {} }
          sec_order[#sec_order + 1] = low
        end
      elseif current_sec then
        local low = current_sec:lower()
        local k, v = trimmed:match("^([^=]+)=(.*)$")
        if k and v then
          local clean_k = trim_str(k):lower()
          local clean_v = unquote_str(v)
          sections[low].kv[clean_k] = clean_v
          sections[low].ordered_values[#sections[low].ordered_values + 1] = { key = clean_k, val = clean_v }
        end
      end
    end
  end

  local folders_meta = sections["folders"]
  local used_sections = { ["folders"] = true }

  if folders_meta then
    local nb = tonumber(folders_meta.kv["nbfolders"])
    local indices = {}
    if nb and nb > 0 then
      for i = 0, nb - 1 do
        indices[#indices + 1] = i
      end
    else
      for k, _ in pairs(folders_meta.kv) do
        local idx_str = k:match("^name(%d+)$")
        if idx_str then
          indices[#indices + 1] = tonumber(idx_str)
        end
      end
      table.sort(indices)
    end

    for _, i in ipairs(indices) do
      local folder_name = folders_meta.kv["name" .. tostring(i)]
      local folder_id = folders_meta.kv["id" .. tostring(i)] or tostring(i)
      if folder_name and folder_name ~= "" then
        local sec_key = ("folder" .. tostring(folder_id)):lower()
        used_sections[sec_key] = true
        local f_sec = sections[sec_key]
        local items = {}
        local smart_filters = {}
        if f_sec then
          local item_nb = tonumber(f_sec.kv["nb"])
          local item_indices = {}
          if item_nb and item_nb > 0 then
            for j = 0, item_nb - 1 do
              item_indices[#item_indices + 1] = j
            end
          else
            for k, _ in pairs(f_sec.kv) do
              local j_str = k:match("^item(%d+)$")
              if j_str then
                item_indices[#item_indices + 1] = tonumber(j_str)
              end
            end
            table.sort(item_indices)
          end

          for _, j in ipairs(item_indices) do
            local it_val = f_sec.kv["item" .. tostring(j)]
            local it_type = tonumber(f_sec.kv["type" .. tostring(j)]) or 0
            if it_val and it_val ~= "" then
              -- REAPER Smart Folder filter 标志位: 0x1000000 (16777216)
              if it_type >= 16777216 and (math.floor(it_type / 16777216) % 2 == 1) then
                smart_filters[#smart_filters + 1] = it_val
              else
                items[#items + 1] = it_val
              end
            end
          end
        end
        folders[#folders + 1] = {
          name = folder_name,
          items = items,
          smart_filters = smart_filters,
        }
      end
    end
  end

  -- 兼容直接以 [自定义文件夹名] 作为节名的简写 INI 格式
  for _, sec_low in ipairs(sec_order) do
    if not used_sections[sec_low] and not sec_low:match("^folder%d+$") then
      local f_sec = sections[sec_low]
      local items = {}
      for _, pair in ipairs(f_sec.ordered_values) do
        if pair.key ~= "nb" and not pair.key:match("^type%d+$") and pair.val ~= "" then
          items[#items + 1] = pair.val
        end
      end
      if #items > 0 then
        folders[#folders + 1] = {
          name = f_sec.raw_name,
          items = items,
          smart_filters = {},
        }
      end
    end
  end

  return folders
end

local function read_reaper_resource_file(r, filename)
  if not r or type(filename) ~= "string" or filename == "" then
    return nil
  end
  if type(r.mock_read_resource_file) == "function" then
    return r.mock_read_resource_file(filename)
  end
  if type(r.GetResourcePath) ~= "function" then
    return nil
  end
  local ok_p, res_path = pcall(r.GetResourcePath)
  if not ok_p or type(res_path) ~= "string" or res_path == "" then
    return nil
  end
  -- 单元测试环境（mock_reaper）若未注入 mock_read_resource_file，则不读取宿主磁盘私有文件
  if r._state ~= nil then
    return nil
  end
  local sep = res_path:match("\\") and "\\" or "/"
  local full_path = res_path:gsub("[/\\]+$", "") .. sep .. filename
  local ok_io, content = pcall(function()
    local f = io.open(full_path, "r")
    if not f then
      return nil
    end
    local data = f:read("*a")
    f:close()
    return data
  end)
  if ok_io then
    return content
  end
  return nil
end

local LEGACY_CATEGORY_ALIASES = {
  ["equalizer"] = "EQ",
  ["eq & filter"] = "EQ",
  ["reverb & delay"] = "Reverb",
  ["preamp & saturation"] = "Distortion",
  ["modulation & pitch"] = "Modulation",
  ["utility & metering"] = "Utility",
}

--- 解析 REAPER reaper-dxplugins64.ini / reaper-dxplugins.ini 内容，提取启用状态 (Load ~= 0) 的 DX / DXi 插件列表
function core.parse_dxplugins_ini(content)
  local plugins = {}
  if type(content) ~= "string" or content == "" then
    return plugins
  end

  local sections = {}
  local current_sec = nil

  for line in content:gmatch("[^\r\n]+") do
    local trimmed = trim_str(line)
    if trimmed ~= "" and not trimmed:match("^[;#]") then
      local sec_name = trimmed:match("^%[([^%]]+)%]$")
      if sec_name then
        current_sec = {
          ident = trim_str(sec_name),
          kv = {},
        }
        sections[#sections + 1] = current_sec
      elseif current_sec then
        local k, v = trimmed:match("^([^=]+)=(.*)$")
        if k and v then
          local clean_k = trim_str(k):lower()
          local clean_v = unquote_str(v)
          current_sec.kv[clean_k] = clean_v
        end
      end
    end
  end

  for _, sec in ipairs(sections) do
    local raw_name = trim_str(sec.kv["name"] or "")
    if raw_name ~= "" then
      local load_str = sec.kv["load"]
      local is_enabled = true
      if load_str ~= nil and trim_str(load_str) ~= "" then
        local load_num = tonumber(load_str)
        if load_num ~= nil then
          is_enabled = (load_num ~= 0)
        elseif trim_str(load_str):lower() == "false" then
          is_enabled = false
        end
      end

      if is_enabled then
        local display_name = raw_name
        local prefix = raw_name:match("^([%w_]+):%s+")
        if not prefix then
          local dxi_flag = tonumber(sec.kv["dxi"] or sec.kv["isinst"] or "0") or 0
          local load_num = tonumber(load_str or "1") or 1
          if dxi_flag ~= 0 or load_num == 2 then
            display_name = "DXi: " .. raw_name
          else
            display_name = "DX: " .. raw_name
          end
        end
        plugins[#plugins + 1] = {
          name = display_name,
          ident = (sec.ident ~= "" and sec.ident) or display_name,
        }
      end
    end
  end

  return plugins
end

--- 根据 reaper-fxtags.ini 标签或插件名称/标识符智能推断功能分类（对齐 REAPER 原生分类名，消除重复分裂）
function core.infer_fx_category(name, ident, tag_category, is_instrument)
  if type(tag_category) == "string" and trim_str(tag_category) ~= "" then
    local primary = trim_str(tag_category:match("^([^|]+)") or tag_category)
    if primary ~= "" then
      local low_p = primary:lower()
      if low_p == "instrument" or low_p == "instruments" or low_p == "synth" or low_p == "synthesizer" then
        if is_instrument then
          return "Instruments"
        end
        -- 若属于被豁免的 DXi 音频效果器例外 (is_instrument == false)，则忽略误标的 Instrument 标签，继续按名称推断效果器分类
      else
        return LEGACY_CATEGORY_ALIASES[low_p] or primary
      end
    end
  end

  if is_instrument then
    return "Instruments"
  end

  local _, short_name = core.parse_fx_display_name(name, ident)
  local raw_name = (type(short_name) == "string" and short_name ~= "") and short_name or ((type(name) == "string") and name or "")
  local raw_ident = (type(ident) == "string") and ident or ""
  local text = (raw_name .. " " .. raw_ident):lower()
  -- 剥离厂商名 "fabfilter" 与单词 "sequencer"，防止 "fabfilter" 误触发 "filter" 或 "sequencer" 误触发 "eq"
  local clean_text = text:gsub("fabfilter", " "):gsub("sequencer", " ")

  if clean_text:find("eq", 1, true)
    or clean_text:find("equalizer", 1, true)
    or clean_text:find("pro-q", 1, true)
    or clean_text:find("pultec", 1, true)
    or clean_text:find("550", 1, true)
    or clean_text:find("560", 1, true) then
    return "EQ"
  end

  if clean_text:find("filter", 1, true)
    or clean_text:find("volcano", 1, true)
    or clean_text:find("simplon", 1, true)
    or clean_text:find("wah", 1, true) then
    return "Filter"
  end

  if clean_text:find("comp", 1, true)
    or clean_text:find("pro-c", 1, true)
    or clean_text:find("pro-l", 1, true)
    or clean_text:find("pro-g", 1, true)
    or clean_text:find("pro-mb", 1, true)
    or clean_text:find("pro-ds", 1, true)
    or clean_text:find("1176", 1, true)
    or clean_text:find("1175", 1, true)
    or clean_text:find("la-2a", 1, true)
    or clean_text:find("la2a", 1, true)
    or clean_text:find("2500", 1, true)
    or clean_text:find("limit", 1, true)
    or clean_text:find("maximizer", 1, true)
    or clean_text:find("gate", 1, true)
    or clean_text:find("expander", 1, true)
    or clean_text:find("transient", 1, true)
    or clean_text:find("de-ess", 1, true)
    or clean_text:find("deesser", 1, true)
    or clean_text:find("dynamic", 1, true) then
    return "Dynamics"
  end

  if clean_text:find("channel", 1, true)
    or clean_text:find("strip", 1, true)
    or clean_text:find("console", 1, true)
    or clean_text:find("preamp", 1, true)
    or clean_text:find("neve", 1, true)
    or clean_text:find("api", 1, true) then
    return "Channel Strip"
  end

  if clean_text:find("distort", 1, true)
    or clean_text:find("sat", 1, true)
    or clean_text:find("tape", 1, true)
    or clean_text:find("drive", 1, true)
    or clean_text:find("overdrive", 1, true)
    or clean_text:find("clipper", 1, true)
    or clean_text:find("exciter", 1, true)
    or clean_text:find("warm", 1, true)
    or clean_text:find("tube", 1, true)
    or clean_text:find("fuzz", 1, true)
    or clean_text:find("bitcrush", 1, true) then
    return "Distortion"
  end

  if clean_text:find("reverb", 1, true)
    or clean_text:find("verb", 1, true)
    or clean_text:find("pro-r", 1, true)
    or clean_text:find("room", 1, true)
    or clean_text:find("hall", 1, true)
    or clean_text:find("plate", 1, true)
    or clean_text:find("chamber", 1, true)
    or clean_text:find("shimmer", 1, true) then
    return "Reverb"
  end

  if clean_text:find("delay", 1, true)
    or clean_text:find("echo", 1, true)
    or clean_text:find("timeless", 1, true) then
    return "Delay"
  end

  if clean_text:find("chorus", 1, true)
    or clean_text:find("phaser", 1, true)
    or clean_text:find("flanger", 1, true)
    or clean_text:find("tremolo", 1, true)
    or clean_text:find("vibrato", 1, true)
    or clean_text:find("modul", 1, true)
    or clean_text:find("pitch", 1, true)
    or clean_text:find("rotary", 1, true) then
    return "Modulation"
  end

  if clean_text:find("meter", 1, true)
    or clean_text:find("analyz", 1, true)
    or clean_text:find("spectrum", 1, true)
    or clean_text:find("scope", 1, true)
    or clean_text:find("loudness", 1, true)
    or clean_text:find("goniometer", 1, true)
    or clean_text:find("tuner", 1, true) then
    return "Analyzer"
  end

  if clean_text:find("volume", 1, true)
    or clean_text:find("gain", 1, true)
    or clean_text:find("trim", 1, true)
    or clean_text:find("pan", 1, true)
    or clean_text:find("stereo", 1, true)
    or clean_text:find("utility", 1, true) then
    return "Utility"
  end

  return "Other FX"
end

local function tokenize_smart_filter(raw_filter)
  local tokens = {}
  local s = tostring(raw_filter or "")
  local n = #s
  local i = 1
  local has_term = false

  while i <= n do
    local ch = s:sub(i, i)
    if ch:match("%s") then
      i = i + 1
    elseif ch == "(" then
      tokens[#tokens + 1] = { type = "LPAREN" }
      i = i + 1
    elseif ch == ")" then
      tokens[#tokens + 1] = { type = "RPAREN" }
      i = i + 1
    elseif ch == "|" then
      tokens[#tokens + 1] = { type = "OR" }
      i = i + 1
    elseif ch == '"' or ch == "'" then
      local quote = ch
      local j = i + 1
      while j <= n and s:sub(j, j) ~= quote do
        j = j + 1
      end
      local phrase = trim_str(s:sub(i + 1, j - 1)):lower()
      if phrase ~= "" then
        tokens[#tokens + 1] = { type = "TERM", val = phrase }
        has_term = true
      end
      i = j + 1
    else
      local j = i
      while j <= n do
        local c = s:sub(j, j)
        if c:match("%s") or c == "(" or c == ")" or c == "|" or c == '"' or c == "'" then
          break
        end
        j = j + 1
      end
      local word = s:sub(i, j - 1)
      local low = word:lower()
      if low == "and" then
        tokens[#tokens + 1] = { type = "AND" }
      elseif low == "or" then
        tokens[#tokens + 1] = { type = "OR" }
      elseif low == "not" or low == "!" or low == "-" then
        tokens[#tokens + 1] = { type = "NOT" }
      elseif (low:sub(1, 1) == "!" or low:sub(1, 1) == "-") and #low > 1 then
        local rest = unquote_str(low:sub(2))
        if rest ~= "" then
          tokens[#tokens + 1] = { type = "NOT" }
          tokens[#tokens + 1] = { type = "TERM", val = rest }
          has_term = true
        end
      else
        local clean = unquote_str(low)
        if clean ~= "" then
          tokens[#tokens + 1] = { type = "TERM", val = clean }
          has_term = true
        end
      end
      i = j
    end
  end

  return tokens, has_term
end

local function eval_smart_folder_filter(search_text, raw_filter)
  if type(search_text) ~= "string" or type(raw_filter) ~= "string" then
    return false
  end
  local tokens, has_term = tokenize_smart_filter(raw_filter)
  if not has_term or #tokens == 0 then
    return false
  end

  local pos = 1
  local parse_or

  local function peek()
    return tokens[pos]
  end

  local function consume()
    local tok = tokens[pos]
    pos = pos + 1
    return tok
  end

  local function parse_primary()
    local tok = peek()
    if not tok then
      return true
    end
    if tok.type == "LPAREN" then
      consume()
      local val = parse_or()
      if peek() and peek().type == "RPAREN" then
        consume()
      end
      return val
    elseif tok.type == "TERM" then
      consume()
      if tok.val == "" then
        return true
      end
      return string.find(search_text, tok.val, 1, true) ~= nil
    else
      consume()
      return true
    end
  end

  local function parse_not()
    local neg_count = 0
    while peek() and peek().type == "NOT" do
      consume()
      neg_count = neg_count + 1
    end
    local val = parse_primary()
    if neg_count % 2 == 1 then
      return not val
    end
    return val
  end

  local function parse_and()
    local left = parse_not()
    while peek() and peek().type ~= "OR" and peek().type ~= "RPAREN" do
      if peek().type == "AND" then
        consume()
      end
      if not peek() or peek().type == "OR" or peek().type == "RPAREN" then
        break
      end
      local right = parse_not()
      left = (left and right)
    end
    return left
  end

  parse_or = function()
    local left = parse_and()
    while peek() and peek().type == "OR" do
      consume()
      if not peek() or peek().type == "RPAREN" then
        break
      end
      local right = parse_and()
      left = (left or right)
    end
    return left
  end

  local result = parse_or()
  while pos <= #tokens do
    if tokens[pos].type == "RPAREN" then
      pos = pos + 1
    else
      local rhs = parse_or()
      result = (result and rhs)
    end
  end
  return result
end

local function match_item_in_fxfolder(item, folder)
  if not item or not folder then
    return false
  end
  local item_keys = item._lookup_keys or ident_lookup_keys(item.ident, item.name)
  if type(folder.items) == "table" then
    local item_key_set = {}
    for _, k in ipairs(item_keys) do
      item_key_set[k] = true
    end
    for _, raw_target in ipairs(folder.items) do
      local target_keys = ident_lookup_keys(raw_target, raw_target)
      for _, tk in ipairs(target_keys) do
        if item_key_set[tk] then
          return true
        end
      end
    end
  end

  if type(folder.smart_filters) == "table" then
    for _, raw_filter in ipairs(folder.smart_filters) do
      if eval_smart_folder_filter(item._search_text, raw_filter) then
        return true
      end
    end
  end

  return false
end

--------------------------------------------------------------------------------
-- 6.1 脚本内自定义分组 (Cakewalk ProChannel 风格用户自定义分组，持久化于 ExtState)
--------------------------------------------------------------------------------

local function serialize_custom_fx_groups(groups)
  if type(groups) ~= "table" then
    return ""
  end
  local lines = {}
  for _, grp in ipairs(groups) do
    local gname = trim_str(grp.name):gsub("[\r\n\t]", " ")
    if gname ~= "" then
      local parts = { gname }
      if type(grp.items) == "table" then
        for _, it in ipairs(grp.items) do
          local clean_it = trim_str(it):gsub("[\r\n\t]", " ")
          if clean_it ~= "" then
            parts[#parts + 1] = clean_it
          end
        end
      end
      lines[#lines + 1] = table.concat(parts, "\t")
    end
  end
  return table.concat(lines, "\n")
end

local function deserialize_custom_fx_groups(raw)
  local groups = {}
  if type(raw) ~= "string" or raw == "" then
    return groups
  end
  local seen_groups = {}
  for line in raw:gmatch("[^\r\n]+") do
    local parts = {}
    for part in (line .. "\t"):gmatch("([^\t]*)\t") do
      parts[#parts + 1] = trim_str(part)
    end
    local gname = parts[1]
    if gname and gname ~= "" and not seen_groups[gname:lower()] then
      seen_groups[gname:lower()] = true
      local items = {}
      local seen_items = {}
      for i = 2, #parts do
        local it = parts[i]
        if it ~= "" and not seen_items[it:lower()] then
          seen_items[it:lower()] = true
          items[#items + 1] = it
        end
      end
      groups[#groups + 1] = {
        name = gname,
        items = items,
      }
    end
  end
  return groups
end

--- 读取脚本内用户自定义 FX 分组列表
--- @param force_reload boolean|nil 是否强制从 ExtState 重新加载
--- @return table custom_groups
function core.get_custom_fx_groups(force_reload)
  if not force_reload and type(core._custom_fx_groups_cache) == "table" then
    return core._custom_fx_groups_cache
  end
  local r = core.get_reaper()
  local raw = ""
  if r and type(r.GetExtState) == "function" then
    raw = r.GetExtState(core.EXT_SECTION, core.CUSTOM_GROUPS_EXT_KEY) or ""
  end
  local groups = deserialize_custom_fx_groups(raw)
  core._custom_fx_groups_cache = groups
  return groups
end

--- 保存脚本内用户自定义 FX 分组列表至 ExtState
function core.save_custom_fx_groups(groups)
  if type(groups) ~= "table" then
    return false
  end
  local serialized = serialize_custom_fx_groups(groups)
  core._custom_fx_groups_cache = deserialize_custom_fx_groups(serialized)
  local r = core.get_reaper()
  if r and type(r.SetExtState) == "function" then
    r.SetExtState(core.EXT_SECTION, core.CUSTOM_GROUPS_EXT_KEY, serialized, true)
    return true
  end
  return false
end

--- 新建自定义 FX 分组（若同名分组已存在则直接返回成功）
function core.add_custom_fx_group(group_name)
  local gname = trim_str(group_name):gsub("[\r\n\t]", " ")
  if gname == "" then
    return false, "empty group name"
  end
  local groups = core.get_custom_fx_groups()
  for _, grp in ipairs(groups) do
    if grp.name:lower() == gname:lower() then
      return true, grp.name
    end
  end
  groups[#groups + 1] = {
    name = gname,
    items = {},
  }
  core.save_custom_fx_groups(groups)
  return true, gname
end

--- 删除指定名称的自定义 FX 分组
function core.remove_custom_fx_group(group_name)
  local gname = trim_str(group_name)
  if gname == "" then
    return false
  end
  local groups = core.get_custom_fx_groups()
  local new_groups = {}
  local removed = false
  for _, grp in ipairs(groups) do
    if grp.name:lower() == gname:lower() then
      removed = true
    else
      new_groups[#new_groups + 1] = grp
    end
  end
  if removed then
    core.save_custom_fx_groups(new_groups)
  end
  return removed
end

--- 将指定插件（ident 或 name 或插件对象）加入自定义分组（若分组不存在则自动新建）
function core.assign_fx_to_custom_group(group_name, fx_item_or_key)
  local gname = trim_str(group_name):gsub("[\r\n\t]", " ")
  if gname == "" then
    return false, "empty group name"
  end
  local fx_key = ""
  if type(fx_item_or_key) == "table" then
    fx_key = (type(fx_item_or_key.ident) == "string" and fx_item_or_key.ident ~= "")
      and fx_item_or_key.ident
      or tostring(fx_item_or_key.name or "")
  elseif type(fx_item_or_key) == "string" then
    fx_key = fx_item_or_key
  end
  fx_key = trim_str(fx_key):gsub("[\r\n\t]", " ")
  if fx_key == "" then
    return false, "empty fx key"
  end

  local groups = core.get_custom_fx_groups()
  local target_grp = nil
  for _, grp in ipairs(groups) do
    if grp.name:lower() == gname:lower() then
      target_grp = grp
      break
    end
  end
  if not target_grp then
    target_grp = { name = gname, items = {} }
    groups[#groups + 1] = target_grp
  end

  for _, existing in ipairs(target_grp.items) do
    if existing:lower() == fx_key:lower() then
      return true
    end
  end
  target_grp.items[#target_grp.items + 1] = fx_key
  core.save_custom_fx_groups(groups)
  return true
end

--- 将指定插件从自定义分组中移除
function core.remove_fx_from_custom_group(group_name, fx_item_or_key)
  local gname = trim_str(group_name)
  if gname == "" then
    return false
  end
  local keys_to_remove = {}
  if type(fx_item_or_key) == "table" then
    if type(fx_item_or_key.ident) == "string" and fx_item_or_key.ident ~= "" then
      keys_to_remove[trim_str(fx_item_or_key.ident):lower()] = true
    end
    if type(fx_item_or_key.name) == "string" and fx_item_or_key.name ~= "" then
      keys_to_remove[trim_str(fx_item_or_key.name):lower()] = true
    end
  elseif type(fx_item_or_key) == "string" and trim_str(fx_item_or_key) ~= "" then
    keys_to_remove[trim_str(fx_item_or_key):lower()] = true
  end

  local groups = core.get_custom_fx_groups()
  local removed = false
  for _, grp in ipairs(groups) do
    if grp.name:lower() == gname:lower() then
      local kept = {}
      for _, it in ipairs(grp.items) do
        if keys_to_remove[it:lower()] then
          removed = true
        else
          kept[#kept + 1] = it
        end
      end
      grp.items = kept
      break
    end
  end
  if removed then
    core.save_custom_fx_groups(groups)
  end
  return removed
end

--- 判断某个已安装插件是否属于指定的自定义分组
function core.is_fx_in_custom_group(group_name, item)
  local gname = trim_str(group_name)
  if gname == "" or not item then
    return false
  end
  local groups = core.get_custom_fx_groups()
  for _, grp in ipairs(groups) do
    if grp.name:lower() == gname:lower() then
      if type(item) == "string" then
        local low = trim_str(item):lower()
        for _, it in ipairs(grp.items) do
          if it:lower() == low then
            return true
          end
        end
        return false
      end
      return match_item_in_fxfolder(item, grp)
    end
  end
  return false
end

--- 清空已安装插件内存缓存
function core.clear_installed_fx_cache()
  core._installed_fx_cache = nil
  core._fxfolders_cache = nil
end

local function normalize_ident_key(s)
  if type(s) ~= "string" then
    return ""
  end
  local clean = trim_str(s):lower()
  local stripped_guid = clean:match("^%{(.+)%}$")
  return stripped_guid or clean
end

--- 枚举并缓存宿主已安装的 FX 列表（自动过滤空项与裸 Container 容器本体，并解析乐器属性、厂商、分类、REAPER 文件夹与 DX INI 增量兜底）
--- @param force_refresh boolean|nil 是否强制重新扫描（为 true 时先调用 EnumInstalledFX(-1) 尝试刷新宿主列表）
--- @return table installed_fx_list
function core.get_installed_fx(force_refresh)
  if not force_refresh and type(core._installed_fx_cache) == "table" then
    return core._installed_fx_cache
  end

  local r = core.get_reaper()
  local fxtags = core.parse_fxtags_ini(read_reaper_resource_file(r, "reaper-fxtags.ini"))
  local fxfolders = core.parse_fxfolders_ini(read_reaper_resource_file(r, "reaper-fxfolders.ini"))

  local list = {}
  local seen_names = {}
  local seen_idents = {}
  local seen_dx_bare = {}

  local function append_fx_entry(raw_name, raw_ident, entry_idx, deduplicate)
    local clean_name = (type(raw_name) == "string") and trim_str(raw_name) or ""
    local clean_ident = (type(raw_ident) == "string") and trim_str(raw_ident) or ""
    if (clean_name == "" and clean_ident == "")
      or clean_name == "Container"
      or clean_ident == "Container" then
      return
    end

    local display_name = (clean_name ~= "" and clean_name) or clean_ident
    local add_name = (clean_name ~= "" and clean_name) or clean_ident
    local fmt, short_name, parsed_dev = core.parse_fx_display_name(display_name, clean_ident)
    local low_name = display_name:lower()
    local norm_ident = normalize_ident_key(clean_ident)
    local fmt_upper = fmt:upper()
    local is_dx_fmt = (fmt_upper == "DX" or fmt_upper == "DXI")
    local dx_bare_key = is_dx_fmt and trim_str(display_name:gsub("^[%w_]+:%s+", "")):lower() or ""

    if deduplicate then
      if seen_names[low_name] then
        return
      end
      if is_dx_fmt and dx_bare_key ~= "" and seen_dx_bare[dx_bare_key] then
        return
      end
      if norm_ident ~= "" and seen_idents[norm_ident] then
        return
      end
    end

    seen_names[low_name] = true
    if norm_ident ~= "" then
      seen_idents[norm_ident] = true
    end
    if is_dx_fmt and dx_bare_key ~= "" then
      seen_dx_bare[dx_bare_key] = true
    end

    local lookup_keys = ident_lookup_keys(clean_ident, display_name)

    local tag_cat = nil
    local tag_dev = nil
    for _, k in ipairs(lookup_keys) do
      if not tag_cat and fxtags.categories[k] then
        tag_cat = fxtags.categories[k]
      end
      if not tag_dev and fxtags.developers[k] then
        tag_dev = fxtags.developers[k]
      end
    end

    local developer = (tag_dev and tag_dev ~= "") and tag_dev or parsed_dev
    local is_inst = core.is_instrument_fx({ format = fmt, name = display_name, short_name = short_name }, tag_cat)
    local category = core.infer_fx_category(display_name, clean_ident, tag_cat, is_inst)
    local search_text = (clean_name .. " " .. clean_ident .. " " .. developer .. " " .. category):lower()

    local entry = {
      index = entry_idx,
      name = display_name,
      short_name = short_name,
      ident = clean_ident,
      add_name = add_name,
      format = fmt,
      developer = developer,
      tag_category = tag_cat,
      category = category,
      is_instrument = is_inst,
      folders = {},
      _lookup_keys = lookup_keys,
      _search_text = search_text,
    }

    if #fxfolders > 0 then
      for _, folder in ipairs(fxfolders) do
        if match_item_in_fxfolder(entry, folder) then
          entry.folders[#entry.folders + 1] = folder.name
        end
      end
    end

    list[#list + 1] = entry
  end

  if type(r.EnumInstalledFX) == "function" then
    if force_refresh then
      pcall(r.EnumInstalledFX, -1)
    end
    local idx = 0
    local max_scan = 50000
    while idx < max_scan do
      local ok, name, ident = r.EnumInstalledFX(idx)
      if not ok then
        break
      end
      append_fx_entry(name, ident, idx, false)
      idx = idx + 1
    end

    -- 补充解析 reaper-dxplugins64.ini（回退兼容 reaper-dxplugins.ini），解决运行中途新扫 DX 插件在重启 REAPER 前未被 EnumInstalledFX 返回的问题
    local dx_ini = read_reaper_resource_file(r, "reaper-dxplugins64.ini")
    if not dx_ini or dx_ini == "" then
      dx_ini = read_reaper_resource_file(r, "reaper-dxplugins.ini")
    end
    if type(dx_ini) == "string" and dx_ini ~= "" then
      local dx_plugins = core.parse_dxplugins_ini(dx_ini)
      for _, dx_item in ipairs(dx_plugins) do
        append_fx_entry(dx_item.name, dx_item.ident, idx, true)
        idx = idx + 1
      end
    end
  end

  core._installed_fx_cache = list
  core._fxfolders_cache = fxfolders
  return list
end

--- 按关键词即时搜索过滤已安装插件（默认过滤掉 VSTi/VST3i/CLAPi/AUi/LV2i 等合成器/乐器插件）
--- @param query string|nil 搜索关键词（空格分隔多词需同时命中）
--- @param max_results number|nil 可选返回上限（省略或 <=0 则返回全部命中项）
--- @param force_refresh boolean|nil 是否在过滤前强制刷新已安装插件缓存
--- @param opts table|boolean|nil 可选过滤项：{ include_instruments = boolean, category = string, developer = string, format = string, folder = string, custom_group = string }（传 true 等价于 { include_instruments = true }）
--- @return table results, number total_matched
function core.filter_installed_fx(query, max_results, force_refresh, opts)
  local all_fx = core.get_installed_fx(force_refresh)
  local include_instruments = false
  local filter_category = nil
  local filter_developer = nil
  local filter_format = nil
  local filter_folder = nil
  local filter_custom_group = nil

  if type(opts) == "boolean" then
    include_instruments = opts
  elseif type(opts) == "table" then
    include_instruments = (opts.include_instruments == true)
    filter_category = (type(opts.category) == "string" and opts.category ~= "") and opts.category:lower() or nil
    filter_developer = (type(opts.developer) == "string" and opts.developer ~= "") and opts.developer:lower() or nil
    filter_format = (type(opts.format) == "string" and opts.format ~= "") and opts.format:lower() or nil
    filter_folder = (type(opts.folder) == "string" and opts.folder ~= "") and opts.folder:lower() or nil
    filter_custom_group = (type(opts.custom_group) == "string" and opts.custom_group ~= "") and opts.custom_group or nil
  end

  local tokens = {}
  if type(query) == "string" and query ~= "" then
    for tok in query:lower():gmatch("%S+") do
      tokens[#tokens + 1] = tok
    end
  end

  local limit = (is_integer(max_results) and max_results > 0) and max_results or nil
  local results = {}
  local total_matched = 0

  for i = 1, #all_fx do
    local item = all_fx[i]
    local matched = true

    if not include_instruments and item.is_instrument then
      matched = false
    end

    if matched and filter_category then
      if tostring(item.category or ""):lower() ~= filter_category then
        matched = false
      end
    end

    if matched and filter_developer then
      if tostring(item.developer or ""):lower() ~= filter_developer then
        matched = false
      end
    end

    if matched and filter_format then
      if tostring(item.format or ""):lower() ~= filter_format then
        matched = false
      end
    end

    if matched and filter_folder then
      local hit_folder = false
      if type(item.folders) == "table" then
        for _, fn in ipairs(item.folders) do
          if fn:lower() == filter_folder then
            hit_folder = true
            break
          end
        end
      end
      if not hit_folder then
        matched = false
      end
    end

    if matched and filter_custom_group then
      if not core.is_fx_in_custom_group(filter_custom_group, item) then
        matched = false
      end
    end

    if matched then
      for t = 1, #tokens do
        if not string.find(item._search_text, tokens[t], 1, true) then
          matched = false
          break
        end
      end
    end

    if matched then
      total_matched = total_matched + 1
      if not limit or #results < limit then
        results[#results + 1] = item
      end
    end
  end

  return results, total_matched
end

local function cap_group_items(items, limit)
  local total = #items
  if not limit or total <= limit then
    return items, total
  end
  local capped = {}
  for i = 1, limit do
    capped[i] = items[i]
  end
  return capped, total
end

--- 按指定分组维度构建过滤后的插件分组视图（支持自定义分组、REAPER fxfolders.ini 文件夹、功能分类、厂商与格式分组）
--- @param query string|nil 搜索关键词
--- @param group_mode string|nil "category" (默认：自定义分组+REAPER文件夹+A-Z功能分类) | "custom" (仅自定义分组与REAPER文件夹) | "developer" (按厂商) | "format" (按格式) | "flat" (平铺)
--- @param opts table|nil 可选参数：{ include_instruments = boolean, max_results = number, force_refresh = boolean }
--- @return table groups, number total_matched
function core.get_grouped_installed_fx(query, group_mode, opts)
  local mode = (type(group_mode) == "string" and group_mode ~= "") and group_mode:lower() or "category"
  local max_res = (type(opts) == "table" and is_integer(opts.max_results) and opts.max_results > 0) and opts.max_results or nil
  local force_ref = (type(opts) == "table") and opts.force_refresh or false
  -- 注意：分组模式下必须先对全量匹配项完成分桶，再对单组按需截断，严禁在分桶前截断导致排在后面的自定义分组/厂商/格式丢失
  local pre_limit = (mode == "flat") and max_res or nil
  local matched_items, total_matched = core.filter_installed_fx(query, pre_limit, force_ref, opts)

  local has_query = (type(query) == "string" and trim_str(query) ~= "")
  local groups = {}

  if mode == "flat" then
    if #matched_items > 0 then
      groups[#groups + 1] = {
        name = "全部插件",
        source = "flat",
        items = matched_items,
        total_items = total_matched,
      }
    end
    return groups, total_matched
  end

  -- 1. 在 "category" 与 "custom" 模式下，展示脚本内自定义分组与 REAPER reaper-fxfolders.ini 自定义文件夹
  if mode == "category" or mode == "custom" then
    local custom_groups = core.get_custom_fx_groups()
    for _, cgrp in ipairs(custom_groups) do
      local grp_items = {}
      for _, item in ipairs(matched_items) do
        if match_item_in_fxfolder(item, cgrp) then
          grp_items[#grp_items + 1] = item
        end
      end
      if #grp_items > 0 or (mode == "custom" and not has_query) then
        local capped_items, total_cnt = cap_group_items(grp_items, max_res)
        groups[#groups + 1] = {
          name = "★ " .. cgrp.name,
          raw_name = cgrp.name,
          source = "custom",
          items = capped_items,
          total_items = total_cnt,
        }
      end
    end

    local fxfolders = core._fxfolders_cache or {}
    for _, folder in ipairs(fxfolders) do
      local folder_items = {}
      for _, item in ipairs(matched_items) do
        if type(item.folders) == "table" then
          for _, fn in ipairs(item.folders) do
            if fn == folder.name then
              folder_items[#folder_items + 1] = item
              break
            end
          end
        end
      end
      if #folder_items > 0 then
        local capped_items, total_cnt = cap_group_items(folder_items, max_res)
        groups[#groups + 1] = {
          name = "📁 " .. folder.name,
          raw_name = folder.name,
          source = "fxfolder",
          items = capped_items,
          total_items = total_cnt,
        }
      end
    end

    if mode == "custom" then
      return groups, total_matched
    end
  end

  -- 2. 按功能分类 / 厂商 / 格式聚合（功能分类严格按 A–Z 纯字母序排列，不强插人为信号流权重）
  local bucket_map = {}
  local bucket_names = {}

  for _, item in ipairs(matched_items) do
    local bname = ""
    if mode == "developer" then
      bname = (item.developer and item.developer ~= "") and item.developer or "Other / Unknown"
    elseif mode == "format" then
      bname = (item.format and item.format ~= "") and item.format or "Other"
    else
      bname = (item.category and item.category ~= "") and item.category or "Other FX"
    end

    if not bucket_map[bname] then
      bucket_map[bname] = {}
      bucket_names[#bucket_names + 1] = bname
    end
    local b_list = bucket_map[bname]
    b_list[#b_list + 1] = item
  end

  table.sort(bucket_names, function(a, b)
    if mode == "developer" then
      if a == "Other / Unknown" then
        return false
      elseif b == "Other / Unknown" then
        return true
      end
    end
    local la = a:lower()
    local lb = b:lower()
    if la ~= lb then
      return la < lb
    end
    return a < b
  end)

  for _, bname in ipairs(bucket_names) do
    local capped_items, total_cnt = cap_group_items(bucket_map[bname], max_res)
    groups[#groups + 1] = {
      name = bname,
      raw_name = bname,
      source = mode,
      items = capped_items,
      total_items = total_cnt,
    }
  end

  return groups, total_matched
end

--------------------------------------------------------------------------------
-- 7. 双区视图模型生成（供 ui.lua 与单元测试消费）
--------------------------------------------------------------------------------

local function get_track_display_name(r, tr)
  if r.GetTrackName then
    local ok, name = r.GetTrackName(tr)
    if ok and name and name ~= "" then
      return name
    end
  end
  if r.GetSetMediaTrackInfo_String then
    local ok, name = r.GetSetMediaTrackInfo_String(tr, "P_NAME", "", false)
    if ok and name and name ~= "" then
      return name
    end
  end
  return "Unnamed Track"
end

--- 生成当前选中轨道的完整双区视图模型
--- @param tr any MediaTrack (可为 nil)
--- @param settings table|nil 可选配置表 { auto_snap_slot0 = bool, follow_host_theme = bool }
function core.build_view_model(tr, settings)
  local vm = {
    has_track = false,
    track = tr,
    track_name = "",
    strip = {
      initialized = false,
      container_index = nil,
      container_guid = nil,
      is_stale_guid = false,
      name = core.STRIP_DEFAULT_NAME,
      enabled = false,
      is_displaced = false,
      displaced_pos = nil,
      auto_snapped = false,
      children = {},
    },
    normal_fx = {},
  }

  if not tr then
    return vm
  end

  local r = core.get_reaper()
  vm.has_track = true
  vm.track_name = get_track_display_name(r, tr)

  local strip_idx, saved_guid, is_stale = core.find_strip_container(tr)
  vm.strip.is_stale_guid = is_stale

  -- 若开启了 Auto-Snap Strip to Slot 0 且检测到偏离，则自动归位至 index 0
  if strip_idx ~= nil and strip_idx > 0 and settings and settings.auto_snap_slot0 then
    local ok_snap, moved = core.snap_strip_to_top(tr)
    if ok_snap and moved then
      strip_idx, saved_guid, is_stale = core.find_strip_container(tr)
      vm.strip.auto_snapped = true
    end
  end

  if strip_idx ~= nil then
    local _, c_name = r.TrackFX_GetFXName(tr, strip_idx, "")
    vm.strip.initialized = true
    vm.strip.container_index = strip_idx
    vm.strip.container_guid = saved_guid
    vm.strip.name = (c_name and c_name ~= "") and c_name or core.STRIP_DEFAULT_NAME
    vm.strip.enabled = (r.TrackFX_GetEnabled(tr, strip_idx) ~= false)
    vm.strip.is_displaced = (strip_idx > 0)
    vm.strip.displaced_pos = (strip_idx > 0) and (strip_idx + 1) or nil
    vm.strip.children = core.get_strip_children(tr, strip_idx)
  end

  vm.normal_fx = core.get_normal_fx_list(tr, strip_idx)
  return vm
end

return core
