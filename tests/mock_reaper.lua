-- tests/mock_reaper.lua
-- 纯 Lua 模拟 REAPER 7.06+ 轨道、顶层 FX、Container 编址、GUID 与 P_EXT 的测试桩

local mock_reaper = {}

local CONTAINER_BASE = 0x2000000

local function deep_copy_fx(node, next_guid_fn)
  local copy = {
    guid = next_guid_fn(),
    ident = node.ident,
    renamed_name = node.renamed_name,
    enabled = node.enabled,
    open = node.open,
    is_container = node.is_container,
    children = {},
  }
  if node.children then
    for i, child in ipairs(node.children) do
      copy.children[i] = deep_copy_fx(child, next_guid_fn)
    end
  end
  return copy
end

function mock_reaper.new()
  local state = {
    tracks = {},
    selected_track = nil,
    state_change_count = 0,
    guid_counter = 0,
    ext_state = {},
    undo_history = {},
    in_undo_block = false,
  }

  local api = {}
  api._state = state

  local function bump_state()
    state.state_change_count = state.state_change_count + 1
  end

  local function next_guid()
    state.guid_counter = state.guid_counter + 1
    return string.format("{MOCK-GUID-%04d}", state.guid_counter)
  end

  -- 内部解析 fx_idx（兼容顶层 0-based 索引与 0x2000000+ 容器子项编址）
  local function resolve_fx(tr, fx_idx)
    if not tr or type(fx_idx) ~= "number" or fx_idx < 0 then
      return nil, nil, nil, nil
    end
    if fx_idx < CONTAINER_BASE then
      local idx_1 = fx_idx + 1
      return tr.fx_chain[idx_1], tr.fx_chain, idx_1, nil
    end

    local parent_cnt = #tr.fx_chain
    local stride = parent_cnt + 1
    local offset = fx_idx - CONTAINER_BASE
    local container_idx_1 = offset % stride
    local child_pos_1 = math.floor(offset / stride)
    if container_idx_1 < 1 or child_pos_1 < 1 then
      return nil, nil, nil, nil
    end
    local container = tr.fx_chain[container_idx_1]
    if not container or not container.is_container then
      return nil, nil, nil, nil
    end
    return container.children[child_pos_1], container.children, child_pos_1, container
  end

  ----------------------------------------------------------------------------
  -- 测试辅助方法（以 _ 或 mock_ 开头，供 tests/run.lua 构造测试场景）
  ----------------------------------------------------------------------------

  function api.mock_add_track(name, select_it)
    local tr = {
      name = name or ("Track " .. tostring(#state.tracks + 1)),
      p_ext = {},
      fx_chain = {},
    }
    state.tracks[#state.tracks + 1] = tr
    if select_it ~= false then
      state.selected_track = tr
    end
    bump_state()
    return tr
  end

  function api.mock_set_selected_track(tr)
    state.selected_track = tr
    bump_state()
  end

  ----------------------------------------------------------------------------
  -- REAPER 标准 API 模拟
  ----------------------------------------------------------------------------

  function api.GetProjectStateChangeCount(_proj)
    return state.state_change_count
  end

  function api.GetSelectedTrack(_proj, selidx)
    if selidx == 0 or selidx == nil then
      return state.selected_track
    end
    return nil
  end

  function api.GetTrackName(tr)
    if not tr then
      return false, ""
    end
    return true, tr.name or ""
  end

  function api.GetSetMediaTrackInfo_String(tr, parmname, stringNeedBig, setNewValue)
    if not tr or type(parmname) ~= "string" then
      return false, ""
    end
    if parmname == "P_NAME" then
      if setNewValue then
        tr.name = tostring(stringNeedBig or "")
        bump_state()
      end
      return true, tr.name or ""
    end

    if setNewValue then
      tr.p_ext[parmname] = tostring(stringNeedBig or "")
      bump_state()
      return true, tr.p_ext[parmname]
    else
      local val = tr.p_ext[parmname]
      if val == nil then
        return false, ""
      end
      return true, val
    end
  end

  function api.TrackFX_GetCount(tr)
    if not tr then
      return 0
    end
    return #tr.fx_chain
  end

  function api.TrackFX_AddByName(tr, fxname, _recFX, instantiate)
    if not tr or type(fxname) ~= "string" or fxname == "" or fxname:match("^__MISSING__") then
      return -1
    end
    if instantiate == 0 then
      for i, node in ipairs(tr.fx_chain) do
        if node.ident == fxname or node.renamed_name == fxname then
          return i - 1
        end
      end
      return -1
    end

    local node = {
      guid = next_guid(),
      ident = fxname,
      renamed_name = nil,
      enabled = true,
      open = false,
      is_container = (fxname == "Container"),
      children = {},
    }

    local insert_pos_1 = #tr.fx_chain + 1
    if type(instantiate) == "number" and instantiate <= -1000 then
      local target_0 = -1000 - instantiate
      insert_pos_1 = math.min(#tr.fx_chain + 1, math.max(1, target_0 + 1))
    end

    table.insert(tr.fx_chain, insert_pos_1, node)
    bump_state()
    return insert_pos_1 - 1
  end

  function api.TrackFX_GetFXGUID(tr, fx_idx)
    local node = resolve_fx(tr, fx_idx)
    if not node then
      return nil
    end
    return node.guid
  end

  function api.TrackFX_GetFXName(tr, fx_idx, _buf)
    local node = resolve_fx(tr, fx_idx)
    if not node then
      return false, ""
    end
    local display = (node.renamed_name and node.renamed_name ~= "") and node.renamed_name or node.ident
    return true, display
  end

  function api.TrackFX_GetEnabled(tr, fx_idx)
    local node = resolve_fx(tr, fx_idx)
    if not node then
      return false
    end
    return node.enabled and true or false
  end

  function api.TrackFX_SetEnabled(tr, fx_idx, enabled)
    local node = resolve_fx(tr, fx_idx)
    if not node then
      return
    end
    node.enabled = (enabled and true or false)
    bump_state()
  end

  function api.TrackFX_GetOpen(tr, fx_idx)
    local node = resolve_fx(tr, fx_idx)
    if not node then
      return false
    end
    return node.open and true or false
  end

  function api.TrackFX_Show(tr, fx_idx, showflag)
    local node = resolve_fx(tr, fx_idx)
    if not node then
      return
    end
    if showflag == 3 or showflag == 1 then
      node.open = true
    elseif showflag == 2 or showflag == 0 then
      node.open = false
    end
    bump_state()
  end

  function api.TrackFX_GetNamedConfigParm(tr, fx_idx, parmname)
    local node, _, idx_1 = resolve_fx(tr, fx_idx)
    if not node or type(parmname) ~= "string" then
      return false, ""
    end
    if parmname == "renamed_name" then
      return true, node.renamed_name or ""
    end
    if parmname == "container_count" then
      if not node.is_container then
        return false, ""
      end
      return true, tostring(#node.children)
    end
    local child_0_str = parmname:match("^container_item%.(%d+)$")
    if child_0_str then
      if not node.is_container then
        return false, ""
      end
      local child_0 = tonumber(child_0_str)
      if not child_0 or child_0 < 0 or child_0 >= #node.children then
        return false, ""
      end
      local container_idx_0 = idx_1 - 1
      local parent_cnt = #tr.fx_chain
      local encoded = CONTAINER_BASE
        + (child_0 + 1) * (parent_cnt + 1)
        + (container_idx_0 + 1)
      return true, tostring(encoded)
    end
    return false, ""
  end

  function api.TrackFX_SetNamedConfigParm(tr, fx_idx, parmname, value)
    local node = resolve_fx(tr, fx_idx)
    if not node or type(parmname) ~= "string" then
      return false
    end
    if parmname == "renamed_name" then
      node.renamed_name = tostring(value or "")
      bump_state()
      return true
    end
    return false
  end

  function api.TrackFX_Delete(tr, fx_idx)
    local node, list, idx_1 = resolve_fx(tr, fx_idx)
    if not node or not list or not idx_1 then
      return false
    end
    table.remove(list, idx_1)
    bump_state()
    return true
  end

  function api.TrackFX_CopyToTrack(src_tr, src_fx, dst_tr, dst_fx, is_move)
    if not src_tr or not dst_tr then
      return false
    end
    local src_node, src_list, src_idx_1 = resolve_fx(src_tr, src_fx)
    if not src_node or not src_list or not src_idx_1 then
      return false
    end

    -- 注意：必须在移除 src_node 之前按当前 #dst_tr.fx_chain 解码目标容器与位置
    local dst_list = nil
    local dst_idx_1 = nil
    if dst_fx < CONTAINER_BASE then
      dst_list = dst_tr.fx_chain
      dst_idx_1 = dst_fx + 1
    else
      local parent_cnt = #dst_tr.fx_chain
      local stride = parent_cnt + 1
      local offset = dst_fx - CONTAINER_BASE
      local container_idx_1 = offset % stride
      local child_pos_1 = math.floor(offset / stride)
      local container = dst_tr.fx_chain[container_idx_1]
      if not container or not container.is_container then
        error("TrackFX_CopyToTrack: destination is not a valid Container")
      end
      dst_list = container.children
      dst_idx_1 = child_pos_1
    end

    local payload = src_node
    if is_move then
      table.remove(src_list, src_idx_1)
    else
      payload = deep_copy_fx(src_node, next_guid)
    end

    dst_idx_1 = math.min(#dst_list + 1, math.max(1, dst_idx_1))
    table.insert(dst_list, dst_idx_1, payload)
    bump_state()
    return true
  end

  function api.GetExtState(section, key)
    local sec = state.ext_state[tostring(section or "")]
    if not sec then
      return ""
    end
    return sec[tostring(key or "")] or ""
  end

  function api.SetExtState(section, key, val, _persist)
    local sec_name = tostring(section or "")
    state.ext_state[sec_name] = state.ext_state[sec_name] or {}
    state.ext_state[sec_name][tostring(key or "")] = tostring(val or "")
  end

  function api.Undo_BeginBlock()
    state.in_undo_block = true
  end

  function api.Undo_EndBlock(desc, _flags)
    state.in_undo_block = false
    state.undo_history[#state.undo_history + 1] = tostring(desc or "")
  end

  return api
end

return mock_reaper
