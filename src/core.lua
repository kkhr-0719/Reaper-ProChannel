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

--- 注入自定义或 Mock 的 reaper API 表（传入 nil 则回退至全局 _G.reaper，并重置已安装插件缓存）
function core.set_reaper(r)
  core._reaper = r
  core._installed_fx_cache = nil
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
--- @return boolean ok, number|nil applied_wet
function core.set_fx_wet(tr, fx_id, wet_0_to_1, record_undo)
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
  if use_undo then
    begin_undo(r)
  end
  local ok = false
  if type(r.TrackFX_SetParam) == "function" then
    local ret = r.TrackFX_SetParam(tr, fx_id, param_idx, clamped)
    ok = (ret ~= false)
  elseif type(r.TrackFX_SetParamNormalized) == "function" then
    local ret = r.TrackFX_SetParamNormalized(tr, fx_id, param_idx, clamped)
    ok = (ret ~= false)
  end
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
-- 6. 已安装插件枚举缓存与关键词搜索过滤（基于 reaper.EnumInstalledFX）
--------------------------------------------------------------------------------

--- 清空已安装插件内存缓存
function core.clear_installed_fx_cache()
  core._installed_fx_cache = nil
end

--- 枚举并缓存宿主已安装的 FX 列表（自动过滤空项与裸 Container 容器本体）
--- @param force_refresh boolean|nil 是否强制重新扫描
--- @return table installed_fx_list
function core.get_installed_fx(force_refresh)
  if not force_refresh and type(core._installed_fx_cache) == "table" then
    return core._installed_fx_cache
  end

  local r = core.get_reaper()
  local list = {}
  if type(r.EnumInstalledFX) == "function" then
    local idx = 0
    local max_scan = 50000
    while idx < max_scan do
      local ok, name, ident = r.EnumInstalledFX(idx)
      if not ok then
        break
      end
      local clean_name = (type(name) == "string") and name or ""
      local clean_ident = (type(ident) == "string") and ident or ""
      if (clean_name ~= "" or clean_ident ~= "")
        and clean_name ~= "Container"
        and clean_ident ~= "Container" then
        local display_name = (clean_name ~= "" and clean_name) or clean_ident
        local add_name = (clean_name ~= "" and clean_name) or clean_ident
        local fmt = display_name:match("^([%w_]+):%s+") or ""
        local search_text = (clean_name .. " " .. clean_ident):lower()
        list[#list + 1] = {
          index = idx,
          name = display_name,
          ident = clean_ident,
          add_name = add_name,
          format = fmt,
          _search_text = search_text,
        }
      end
      idx = idx + 1
    end
  end

  core._installed_fx_cache = list
  return list
end

--- 按关键词即时搜索过滤已安装插件（支持空格分词多关键词与特殊字符纯文本子串匹配）
--- @param query string|nil 搜索关键词（空格分隔多词需同时命中）
--- @param max_results number|nil 可选返回上限（省略或 <=0 则返回全部命中项）
--- @param force_refresh boolean|nil 是否在过滤前强制刷新已安装插件缓存
--- @return table results, number total_matched
function core.filter_installed_fx(query, max_results, force_refresh)
  local all_fx = core.get_installed_fx(force_refresh)
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
    for t = 1, #tokens do
      if not string.find(item._search_text, tokens[t], 1, true) then
        matched = false
        break
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
