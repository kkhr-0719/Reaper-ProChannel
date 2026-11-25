-- src/ui.lua
-- Reaper ProChannel (ReaPCh) — 薄渲染层 (Studio Dark / 宿主自适应视觉体系 + MIX 圆弧旋钮 + 精细布局精修)
-- 职责：消费 core.lua 输出的双区视图模型，绘制固定吸顶轨道栏、可停靠双区卡片面板、双区独立 + 插件分组搜索弹窗
--       （默认过滤 Synth 乐器、支持 REAPER 原生与自定义分组）、单行硬件感 Bypass 指示灯、单行 ImDrawList 圆弧 MIX (Wet/Dry) 旋钮、
--       整行无死角区内/跨区双向拖拽高亮插入线反馈、偏离提示条卡片与右上角设置菜单。
-- 说明：完整保留 REAPER / ReaImGui 原生 Docking 与 Split Dock 特性；所有可选 ImGui API 一律通过 rawget 安全探测。

local core = require("core")
local theme = require("theme")

local DND_PAYLOAD_TYPE = "REAPCH_DND_FX"
local KNOB_ARC_MIN = 0.75 * math.pi  -- 135 deg (7:30 位置)
local KNOB_ARC_MAX = 2.25 * math.pi  -- 405 deg (4:30 位置，顺时针跨度 270 deg)

local ui = {
  _pending_dock_id = nil,
  _last_dock_id = -1,
  _last_track_ptr = nil,
  _pending_open_fx_browser = false,
  _browser_target_zone = "strip", -- "strip" | "normal"
  _fx_search_query = "",
  _fx_show_instruments = false,
  _fx_group_mode = "category", -- "category" | "custom" | "developer" | "format" | "flat"
  _show_custom_group_editor = false,
  _new_custom_group_name = "",
  _focus_search_input = false,
  _search_query_just_changed = false,

  -- 单行 MIX 旋钮拖拽与 Undo 基线状态
  _wet_edit_start = {},
  _wet_last_val = {},
  _wet_dirty = {},
  _wet_prev_mouse_y = {},
  _wet_ignore_drag = {},

  -- 跨区/区内拖拽源缓存（用于计算高亮插入线位于目标行顶部还是底部）
  _active_dnd_zone = nil,
  _active_dnd_slot = nil,
  _frame_has_dnd_source = false,
}

local function enum_val(v)
  if type(v) == "function" then
    return v()
  end
  return v or 0
end

local function has_imgui(ImGui, key)
  return rawget(ImGui, key) ~= nil
end

local function push_style_color(ctx, ImGui, col_name, rgba)
  if type(rgba) ~= "number" or not has_imgui(ImGui, "PushStyleColor") then
    return 0
  end
  local raw_enum = rawget(ImGui, col_name)
  if raw_enum == nil then
    return 0
  end
  ImGui.PushStyleColor(ctx, enum_val(raw_enum), rgba)
  return 1
end

local function pop_style_color(ctx, ImGui, count)
  if type(count) == "number" and count > 0 and has_imgui(ImGui, "PopStyleColor") then
    ImGui.PopStyleColor(ctx, count)
  end
end

local function set_mouse_cursor(ctx, ImGui, cursor_name)
  if not has_imgui(ImGui, "SetMouseCursor") then
    return
  end
  local raw_cur = rawget(ImGui, cursor_name)
  if raw_cur ~= nil then
    ImGui.SetMouseCursor(ctx, enum_val(raw_cur))
  end
end

local function calc_text_width(ctx, ImGui, text)
  local s = tostring(text or "")
  if s == "" then
    return 0
  end
  if has_imgui(ImGui, "CalcTextSize") then
    local w = ImGui.CalcTextSize(ctx, s)
    if type(w) == "number" then
      return w
    end
  end
  return #s * 7.0
end

--- 按 UTF-8 字符边界安全截断超长文本并追加省略号 "..."，彻底防止中文乱码与窄侧边栏文字溢出
local function fit_text_with_ellipsis(ctx, ImGui, text, max_w)
  local s = tostring(text or "")
  if s == "" then
    return "", false
  end
  if type(max_w) ~= "number" or max_w <= 0 then
    return "", true
  end
  if not has_imgui(ImGui, "CalcTextSize") then
    return s, false
  end
  if calc_text_width(ctx, ImGui, s) <= max_w then
    return s, false
  end

  local ellipsis = "..."
  local ellipsis_w = calc_text_width(ctx, ImGui, ellipsis)
  if ellipsis_w >= max_w then
    return "", true
  end

  -- 收集每个完整 UTF-8 字符的结束字节索引（绝不在多字节字符中间截断）
  local char_ends = {}
  local len = #s
  local i = 1
  while i <= len do
    local b = s:byte(i)
    local step = 1
    if b >= 0xF0 then
      step = 4
    elseif b >= 0xE0 then
      step = 3
    elseif b >= 0xC0 then
      step = 2
    end
    local next_end = math.min(len, i + step - 1)
    char_ends[#char_ends + 1] = next_end
    i = next_end + 1
  end

  local lo, hi = 1, #char_ends
  local best = 0
  while lo <= hi do
    local mid = math.floor((lo + hi) * 0.5)
    local candidate = s:sub(1, char_ends[mid]) .. ellipsis
    if calc_text_width(ctx, ImGui, candidate) <= max_w then
      best = mid
      lo = mid + 1
    else
      hi = mid - 1
    end
  end

  if best <= 0 then
    return ellipsis, true
  end
  return s:sub(1, char_ends[best]) .. ellipsis, true
end

ui._fit_text_with_ellipsis = fit_text_with_ellipsis

local function clear_wet_edit_state()
  ui._wet_edit_start = {}
  ui._wet_last_val = {}
  ui._wet_dirty = {}
  ui._wet_prev_mouse_y = {}
  ui._wet_ignore_drag = {}
end

local function show_tooltip(ctx, ImGui, primary_text, secondary_text)
  if has_imgui(ImGui, "BeginTooltip") and has_imgui(ImGui, "EndTooltip") then
    if ImGui.BeginTooltip(ctx) then
      ImGui.Text(ctx, tostring(primary_text or ""))
      if secondary_text and secondary_text ~= "" then
        ImGui.TextDisabled(ctx, tostring(secondary_text))
      end
      ImGui.EndTooltip(ctx)
    end
  elseif has_imgui(ImGui, "SetTooltip") then
    if secondary_text and secondary_text ~= "" then
      ImGui.SetTooltip(ctx, tostring(primary_text or "") .. "\n" .. tostring(secondary_text))
    else
      ImGui.SetTooltip(ctx, tostring(primary_text or ""))
    end
  end
end

local function is_shift_held(ctx, ImGui)
  if has_imgui(ImGui, "GetKeyMods") then
    local raw_mod_shift = rawget(ImGui, "Mod_Shift")
    if raw_mod_shift == nil then
      raw_mod_shift = rawget(ImGui, "Key_ModShift")
    end
    if raw_mod_shift ~= nil then
      local mods = ImGui.GetKeyMods(ctx)
      local shift_flag = enum_val(raw_mod_shift)
      if type(mods) == "number" and type(shift_flag) == "number" then
        return (mods & shift_flag) ~= 0
      end
    end
  end
  if has_imgui(ImGui, "IsKeyDown") then
    local lshift = rawget(ImGui, "Key_LeftShift")
    local rshift = rawget(ImGui, "Key_RightShift")
    if lshift ~= nil and ImGui.IsKeyDown(ctx, enum_val(lshift)) then
      return true
    end
    if rshift ~= nil and ImGui.IsKeyDown(ctx, enum_val(rshift)) then
      return true
    end
  end
  return false
end

--- 在 ImDrawList 上绘制圆弧（优先使用 PathArcTo + PathStroke，回退支持 AddLine 分段折线）
local function draw_arc(ImGui, dl, cx, cy, radius, a_min, a_max, col_rgba, thickness, segments)
  if not dl or math.abs(a_max - a_min) < 0.001 then
    return
  end
  local segs = segments or 20
  local thick = thickness or 2.0
  if has_imgui(ImGui, "DrawList_PathArcTo") and has_imgui(ImGui, "DrawList_PathStroke") then
    if has_imgui(ImGui, "DrawList_PathClear") then
      ImGui.DrawList_PathClear(dl)
    end
    ImGui.DrawList_PathArcTo(dl, cx, cy, radius, a_min, a_max, segs)
    ImGui.DrawList_PathStroke(dl, col_rgba, 0, thick)
  elseif has_imgui(ImGui, "DrawList_AddLine") then
    local step = (a_max - a_min) / segs
    local px = cx + math.cos(a_min) * radius
    local py = cy + math.sin(a_min) * radius
    for i = 1, segs do
      local ang = a_min + step * i
      local nx = cx + math.cos(ang) * radius
      local ny = cy + math.sin(ang) * radius
      ImGui.DrawList_AddLine(dl, px, py, nx, ny, col_rgba, thick)
      px, py = nx, ny
    end
  end
end

local function open_fx_browser_popup(_ctx, _ImGui, zone)
  ui._browser_target_zone = (zone == "normal") and "normal" or "strip"
  ui._focus_search_input = true
  -- 通过顶层延迟标志在主窗口 ID 栈层级统一调用 OpenPopup，避免 BeginChild 子作用域导致 Popup ID 不匹配
  ui._pending_open_fx_browser = true
end

--- 解析跨区/区内统一拖拽 Payload ("strip:1" 或 "normal:2")
local function parse_dnd_payload(payload)
  if type(payload) ~= "string" then
    return nil, nil
  end
  local src_zone, slot_str = payload:match("^(%a+):(%d+)$")
  local src_slot = tonumber(slot_str)
  if (src_zone == "strip" or src_zone == "normal") and src_slot and src_slot >= 1 then
    return src_zone, src_slot
  end
  return nil, nil
end

--- 统一处理区内排序与跨区拖入/拖出
local function apply_fx_drop(vm, target_zone, target_slot, payload, mark_dirty)
  local src_zone, src_slot = parse_dnd_payload(payload)
  if not src_zone or not src_slot or not vm or not vm.track then
    return
  end

  if src_zone == "strip" and target_zone == "strip" then
    local dst = target_slot or #vm.strip.children
    if dst >= 1 and src_slot ~= dst then
      core.move_strip_fx(vm.track, src_slot, dst)
      mark_dirty()
    end
  elseif src_zone == "normal" and target_zone == "normal" then
    local dst = target_slot or #vm.normal_fx
    if dst >= 1 and src_slot ~= dst then
      core.move_normal_fx(vm.track, src_slot, dst)
      mark_dirty()
    end
  elseif src_zone == "normal" and target_zone == "strip" then
    -- 从下半区常规槽拖入上半区 0 号位 Channel Strip（若未初始化会自动建容器并置入）
    core.move_normal_fx_to_strip(vm.track, src_slot, target_slot)
    mark_dirty()
  elseif src_zone == "strip" and target_zone == "normal" then
    -- 从上半区 0 号位 Channel Strip 拖出至下半区常规槽
    core.move_strip_fx_to_normal(vm.track, src_slot, target_slot)
    mark_dirty()
  end
end

--- 绘制拖拽悬停时的目标高亮底色与插入指示线
local function draw_drop_target_feedback(ctx, ImGui, target_zone, target_slot, pal, bounds)
  if not pal or not has_imgui(ImGui, "GetWindowDrawList") then
    return
  end
  local dl = ImGui.GetWindowDrawList(ctx)
  if not dl then
    return
  end

  local x1, y1, x2, y2
  if type(bounds) == "table" and bounds.x1 and bounds.y1 and bounds.x2 and bounds.y2 then
    x1, y1, x2, y2 = bounds.x1, bounds.y1, bounds.x2, bounds.y2
  elseif has_imgui(ImGui, "GetItemRectMin") and has_imgui(ImGui, "GetItemRectMax") then
    x1, y1 = ImGui.GetItemRectMin(ctx)
    x2, y2 = ImGui.GetItemRectMax(ctx)
  end
  if not x1 or not y1 or not x2 or not y2 then
    return
  end

  local src_zone = ui._active_dnd_zone
  local src_slot = ui._active_dnd_slot
  if src_zone == target_zone and target_slot ~= nil and src_slot == target_slot then
    return
  end

  if has_imgui(ImGui, "DrawList_AddRectFilled") then
    ImGui.DrawList_AddRectFilled(dl, x1, y1, x2, y2, pal.drag_target_fill, 4.0)
  end

  local line_y = y1
  if target_slot == nil then
    line_y = y2
    if has_imgui(ImGui, "DrawList_AddRect") then
      ImGui.DrawList_AddRect(dl, x1, y1, x2, y2, pal.drag_insert_line, 4.0, 0, 1.3)
    end
  elseif src_zone == target_zone and type(src_slot) == "number" and src_slot < target_slot then
    line_y = y2
  end

  if has_imgui(ImGui, "DrawList_AddLine") then
    ImGui.DrawList_AddLine(dl, x1 + 4, line_y, x2 - 4, line_y, pal.drag_insert_line, 2.4)
  end
  if has_imgui(ImGui, "DrawList_AddCircleFilled") then
    ImGui.DrawList_AddCircleFilled(dl, x1 + 5, line_y, 3.0, pal.drag_insert_line)
    ImGui.DrawList_AddCircleFilled(dl, x2 - 5, line_y, 3.0, pal.drag_insert_line)
  end
end

--- 为当前上一个 ImGui 控件挂载拖拽释放目标（含高亮插入线视觉反馈）
local function attach_zone_drop_target(ctx, ImGui, vm, target_zone, target_slot, mark_dirty, pal, bounds)
  if has_imgui(ImGui, "BeginDragDropTarget") and ImGui.BeginDragDropTarget(ctx) then
    draw_drop_target_feedback(ctx, ImGui, target_zone, target_slot, pal, bounds)
    local ok_dnd, payload = ImGui.AcceptDragDropPayload(ctx, DND_PAYLOAD_TYPE)
    if ok_dnd and payload then
      apply_fx_drop(vm, target_zone, target_slot, payload, mark_dirty)
      ui._active_dnd_zone = nil
      ui._active_dnd_slot = nil
    end
    ImGui.EndDragDropTarget(ctx)
  end
end

--- 绘制弹窗内单个插件条目（点击添加至目标区，右键可加入/移出自定义分组）
local function render_browser_fx_item(ctx, ImGui, vm, item, custom_groups, mark_dirty)
  local added = false
  if ImGui.Selectable(ctx, item.name, false) then
    if ui._browser_target_zone == "strip" then
      core.add_fx_to_strip(vm.track, item.add_name)
    else
      core.add_normal_fx(vm.track, item.add_name)
    end
    mark_dirty()
    added = true
  end

  if has_imgui(ImGui, "BeginPopupContextItem") and ImGui.BeginPopupContextItem(ctx, "browser_item_ctx") then
    ImGui.Text(ctx, item.short_name or item.name)
    if item.developer and item.developer ~= "" then
      ImGui.TextDisabled(ctx, string.format("厂商: %s | 分类: %s", item.developer, tostring(item.category or "")))
    end
    ImGui.Separator(ctx)

    if ImGui.MenuItem(ctx, "添加至当前区域") then
      if ui._browser_target_zone == "strip" then
        core.add_fx_to_strip(vm.track, item.add_name)
      else
        core.add_normal_fx(vm.track, item.add_name)
      end
      mark_dirty()
      added = true
    end

    ImGui.Separator(ctx)
    if #custom_groups == 0 then
      if ImGui.MenuItem(ctx, "★ 加入新分组: 常用通道条 (Favorites)") then
        core.assign_fx_to_custom_group("常用通道条", item)
      end
    else
      for _, cgrp in ipairs(custom_groups) do
        local in_grp = core.is_fx_in_custom_group(cgrp.name, item)
        if in_grp then
          if ImGui.MenuItem(ctx, "从自定义分组移除: " .. cgrp.name) then
            core.remove_fx_from_custom_group(cgrp.name, item)
          end
        else
          if ImGui.MenuItem(ctx, "★ 加入自定义分组: " .. cgrp.name) then
            core.assign_fx_to_custom_group(cgrp.name, item)
          end
        end
      end
    end

    ImGui.EndPopup(ctx)
  end

  return added
end

--- 绘制双区共用的已安装插件搜索与分组添加弹窗（默认过滤 Synth 乐器，支持分类/自定义分组/厂商/格式视图）
local function render_fx_browser_popup(ctx, ImGui, vm, mark_dirty, pal)
  if not ImGui.BeginPopup(ctx, "reapch_fx_browser_popup") then
    return
  end

  if not vm.has_track or not vm.track then
    ImGui.TextDisabled(ctx, "请先在 REAPER 中选中一条轨道")
    ImGui.EndPopup(ctx)
    return
  end

  local is_strip_target = (ui._browser_target_zone == "strip")
  local target_accent = is_strip_target and pal.strip_accent or pal.normal_accent
  local target_title_col = is_strip_target and pal.row_slot_strip or pal.row_slot_normal

  local pushed_title = push_style_color(ctx, ImGui, "Col_Text", target_title_col)
  if is_strip_target then
    ImGui.Text(ctx, "添加插件至: ◆ 0 号位 · Channel Strip")
  else
    ImGui.Text(ctx, "添加插件至: ● 常规 FX 槽 (1..N)")
  end
  pop_style_color(ctx, ImGui, pushed_title)
  ImGui.Separator(ctx)

  if ui._focus_search_input and has_imgui(ImGui, "SetKeyboardFocusHere") then
    ImGui.SetKeyboardFocusHere(ctx)
    ui._focus_search_input = false
  end

  -- 顶部搜索输入栏：固定对齐宽度 390px（避免 AlwaysAutoResize 弹窗内 BeginChild(-1) 宽度塌缩）
  local popup_content_w = 390
  local clear_w = math.max(40, math.ceil(calc_text_width(ctx, ImGui, "清空") + 14))
  local refresh_w = math.max(40, math.ceil(calc_text_width(ctx, ImGui, "刷新") + 14))
  local search_w = math.max(180, popup_content_w - clear_w - refresh_w - 10)

  if has_imgui(ImGui, "SetNextItemWidth") then
    ImGui.SetNextItemWidth(ctx, search_w)
  end
  local chg_q, new_q
  if has_imgui(ImGui, "InputTextWithHint") then
    chg_q, new_q = ImGui.InputTextWithHint(
      ctx,
      "##reapch_fx_search",
      "搜索插件/厂商/分类 (如 eq / fabfilter / comp)...",
      ui._fx_search_query or ""
    )
  else
    chg_q, new_q = ImGui.InputText(
      ctx,
      "##reapch_fx_search",
      ui._fx_search_query or ""
    )
  end
  if chg_q then
    ui._fx_search_query = new_q or ""
    ui._search_query_just_changed = true
  end

  ImGui.SameLine(ctx)
  if ImGui.Button(ctx, "清空##reapch_clear_search", clear_w, 0) then
    ui._fx_search_query = ""
    ui._search_query_just_changed = false
  end

  ImGui.SameLine(ctx)
  if ImGui.Button(ctx, "刷新##reapch_refresh_fx_cache", refresh_w, 0) then
    core.get_installed_fx(true)
    core.get_custom_fx_groups(true)
  end

  -- 乐器/合成器过滤开关（默认不勾选，自动隐藏 VSTi/VST3i/CLAPi/AUi/LV2i）与自定义分组管理按钮
  local chg_inst, val_inst = ImGui.Checkbox(
    ctx,
    "显示乐器/合成器 (VSTi/CLAPi)##reapch_show_inst",
    ui._fx_show_instruments and true or false
  )
  if chg_inst then
    ui._fx_show_instruments = val_inst and true or false
  end

  ImGui.SameLine(ctx)
  local cgrp_btn_label = ui._show_custom_group_editor and "收起分组管理##reapch_cgrp_btn" or "+ 自定义分组##reapch_cgrp_btn"
  if ImGui.Button(ctx, cgrp_btn_label) then
    ui._show_custom_group_editor = not ui._show_custom_group_editor
  end

  -- 脚本内自定义分组快捷新建栏
  if ui._show_custom_group_editor then
    local create_btn_w = math.max(66, math.ceil(calc_text_width(ctx, ImGui, "新建分组") + 14))
    if has_imgui(ImGui, "SetNextItemWidth") then
      ImGui.SetNextItemWidth(ctx, math.max(180, popup_content_w - create_btn_w - 5))
    end
    local chg_cg, new_cg
    if has_imgui(ImGui, "InputTextWithHint") then
      chg_cg, new_cg = ImGui.InputTextWithHint(
        ctx,
        "##reapch_new_cgrp_input",
        "输入新分组名 (如: 常用话放 / 鼓组塑形)...",
        ui._new_custom_group_name or ""
      )
    else
      chg_cg, new_cg = ImGui.InputText(
        ctx,
        "##reapch_new_cgrp_input",
        ui._new_custom_group_name or ""
      )
    end
    if chg_cg then
      ui._new_custom_group_name = new_cg or ""
    end
    ImGui.SameLine(ctx)
    if ImGui.Button(ctx, "新建分组##reapch_create_cgrp_btn", create_btn_w, 0) then
      local ok_add = core.add_custom_fx_group(ui._new_custom_group_name)
      if ok_add then
        ui._new_custom_group_name = ""
      end
    end
    ImGui.TextDisabled(ctx, "提示: 右键下方任意插件可加入/移出自定义分组；也自动读取 REAPER reaper-fxfolders.ini")
  end

  -- 分组维度切换栏（激活态使用目标区域强调色 + 高对比文字色）
  local modes = {
    { id = "category", label = "分类" },
    { id = "custom", label = "自定义/文件夹" },
    { id = "developer", label = "厂商" },
    { id = "format", label = "格式" },
    { id = "flat", label = "平铺" },
  }
  if has_imgui(ImGui, "AlignTextToFramePadding") then
    ImGui.AlignTextToFramePadding(ctx)
  end
  ImGui.TextDisabled(ctx, "分组:")
  local active_btn_text = theme.on_accent_text(target_accent)
  local active_btn_hover = theme.blend_rgba(target_accent, pal.is_light and 0x000000FF or 0xFFFFFFFF, 0.12)
  for _, m in ipairs(modes) do
    ImGui.SameLine(ctx)
    local is_active = (ui._fx_group_mode == m.id)
    local pushed = 0
    if is_active then
      pushed = pushed + push_style_color(ctx, ImGui, "Col_Button", target_accent)
      pushed = pushed + push_style_color(ctx, ImGui, "Col_ButtonHovered", active_btn_hover)
      pushed = pushed + push_style_color(ctx, ImGui, "Col_ButtonActive", target_accent)
      pushed = pushed + push_style_color(ctx, ImGui, "Col_Text", active_btn_text)
    end
    local btn_text = string.format("%s##gmode_%s", m.label, m.id)
    if ImGui.Button(ctx, btn_text) then
      ui._fx_group_mode = m.id
    end
    pop_style_color(ctx, ImGui, pushed)
  end

  local max_limit = 300
  local groups, total_matched = core.get_grouped_installed_fx(
    ui._fx_search_query,
    ui._fx_group_mode,
    {
      include_instruments = ui._fx_show_instruments,
      max_results = max_limit,
    }
  )

  if ui._fx_group_mode == "flat" and total_matched > max_limit then
    ImGui.TextDisabled(
      ctx,
      string.format("匹配 %d 个插件 (平铺仅显示前 %d 个，请继续输入关键词)", total_matched, max_limit)
    )
  else
    ImGui.TextDisabled(
      ctx,
      string.format("匹配 %d 个插件 (%d 个分组)%s", total_matched, #groups, ui._fx_show_instruments and "" or " · 已隐藏乐器")
    )
  end

  local custom_groups = core.get_custom_fx_groups()
  local has_query = (type(ui._fx_search_query) == "string" and ui._fx_search_query:match("%S") ~= nil)
  local auto_expand_search = (has_query and ui._search_query_just_changed)
  ui._search_query_just_changed = false
  local should_close_popup = false
  local list_visible = ImGui.BeginChild(ctx, "reapch_fx_browser_list", popup_content_w, 270)
  if list_visible then
    if #groups == 0 or (total_matched == 0 and ui._fx_group_mode ~= "custom") then
      if ui._fx_group_mode == "custom" then
        ImGui.TextDisabled(ctx, "  (暂无自定义分组或 REAPER 自定义文件夹，可点击上方 [+ 自定义分组] 新建)")
      else
        ImGui.TextDisabled(ctx, "  (未找到匹配的已安装插件)")
      end
    elseif ui._fx_group_mode == "flat" then
      local flat_items = groups[1] and groups[1].items or {}
      for idx, item in ipairs(flat_items) do
        ImGui.PushID(ctx, "flat_" .. tostring(item.index or idx))
        if render_browser_fx_item(ctx, ImGui, vm, item, custom_groups, mark_dirty) then
          should_close_popup = true
        end
        ImGui.PopID(ctx)
      end
    else
      local can_tree = has_imgui(ImGui, "TreeNode") and has_imgui(ImGui, "TreePop")
      local can_set_open = has_imgui(ImGui, "SetNextItemOpen")
      local cond_first = enum_val(rawget(ImGui, "Cond_FirstUseEver"))
      local cond_always = enum_val(rawget(ImGui, "Cond_Always"))

      for g_idx, grp in ipairs(groups) do
        ImGui.PushID(ctx, "grp_" .. tostring(grp.source or "") .. "_" .. tostring(grp.raw_name or grp.name or g_idx))
        local grp_total = tonumber(grp.total_items) or #grp.items
        local grp_header = string.format("%s (%d)###tree_grp", tostring(grp.name or "Group"), grp_total)

        local node_open = true
        if can_tree then
          if can_set_open then
            if auto_expand_search then
              ImGui.SetNextItemOpen(ctx, true, cond_always)
            elseif grp.source == "custom" then
              ImGui.SetNextItemOpen(ctx, true, cond_first)
            end
          end
          node_open = ImGui.TreeNode(ctx, grp_header)
        else
          ImGui.Text(ctx, string.format("%s (%d)", tostring(grp.name or "Group"), grp_total))
        end

        -- 自定义分组标题右键支持删除该分组
        if grp.source == "custom"
          and grp.raw_name
          and has_imgui(ImGui, "BeginPopupContextItem")
          and ImGui.BeginPopupContextItem(ctx, "cgrp_hdr_ctx") then
          if ImGui.MenuItem(ctx, "删除自定义分组: " .. tostring(grp.raw_name)) then
            core.remove_custom_fx_group(grp.raw_name)
          end
          ImGui.EndPopup(ctx)
        end

        if node_open then
          if #grp.items == 0 then
            ImGui.TextDisabled(ctx, "  (分组为空，可在其他分类中右键插件加入此分组)")
          else
            for idx, item in ipairs(grp.items) do
              ImGui.PushID(ctx, tostring(item.index or idx))
              if render_browser_fx_item(ctx, ImGui, vm, item, custom_groups, mark_dirty) then
                should_close_popup = true
              end
              ImGui.PopID(ctx)
            end
            if grp_total > #grp.items then
              ImGui.TextDisabled(
                ctx,
                string.format("  ... 仅显示本组前 %d 项 (共 %d 项)，请输入搜索词继续筛选", #grp.items, grp_total)
              )
            end
          end
          if can_tree then
            ImGui.TreePop(ctx)
          end
        end

        ImGui.PopID(ctx)
      end
    end
    -- ReaImGui 0.9 / 0.10 规范：仅在 BeginChild 返回 true 时调用 EndChild
    ImGui.EndChild(ctx)
  end

  if should_close_popup then
    ImGui.CloseCurrentPopup(ctx)
  end

  ImGui.EndPopup(ctx)
end

--- 绘制单行 Bypass 硬件感指示灯按钮（无 ImDrawList 时回退 Checkbox）
local function render_bypass_led(ctx, ImGui, dl, pal, is_strip, row_on, effectively_enabled, led_w, row_h, on_toggle)
  if dl and has_imgui(ImGui, "InvisibleButton") and has_imgui(ImGui, "DrawList_AddCircleFilled") then
    local clicked = ImGui.InvisibleButton(ctx, "##row_bypass", led_w, row_h)
    local hovered = has_imgui(ImGui, "IsItemHovered") and ImGui.IsItemHovered(ctx) or false
    if clicked then
      on_toggle(not row_on)
    end
    if hovered then
      set_mouse_cursor(ctx, ImGui, "MouseCursor_Hand")
    end

    if has_imgui(ImGui, "GetItemRectMin") and has_imgui(ImGui, "GetItemRectMax") then
      local x1, y1 = ImGui.GetItemRectMin(ctx)
      local x2, y2 = ImGui.GetItemRectMax(ctx)
      local cx = (x1 + x2) * 0.5
      local cy = (y1 + y2) * 0.5

      -- 灯座底盘
      ImGui.DrawList_AddCircleFilled(dl, cx, cy, 5.2, pal.bypass_socket)

      if row_on then
        local glow_col = is_strip and pal.bypass_glow_strip or pal.bypass_glow_normal
        local core_col = is_strip and pal.bypass_on_strip or pal.bypass_on_normal
        if not effectively_enabled then
          core_col = theme.with_alpha(core_col, 140)
        else
          ImGui.DrawList_AddCircleFilled(dl, cx, cy, 6.8, glow_col)
        end
        ImGui.DrawList_AddCircleFilled(dl, cx, cy, 3.8, core_col)
      else
        ImGui.DrawList_AddCircleFilled(dl, cx, cy, 3.2, pal.bypass_off)
      end

      if hovered and has_imgui(ImGui, "DrawList_AddCircle") then
        local ring_col = is_strip and pal.strip_accent or pal.normal_accent
        ImGui.DrawList_AddCircle(dl, cx, cy, 6.4, ring_col, 0, 1.2)
      end
    end

    if hovered then
      show_tooltip(
        ctx,
        ImGui,
        row_on and "状态: 已启用 (Active)" or "状态: 已旁通 (Bypassed)",
        "点击切换单行 Bypass"
      )
    end
    return
  end

  local chg_en, new_en = ImGui.Checkbox(ctx, "##row_bypass", row_on)
  if chg_en then
    on_toggle(new_en)
  end
end

--- 绘制单行紧凑圆弧 MIX（Wet/Dry 干湿比）旋钮（Knob）
--- 交互：InvisibleButton 承接鼠标上下拖拽实时调参不刷 Undo、Shift 微调、松手沿用 pre_undo_wet_0_to_1 基线恢复确保 Ctrl+Z 一步退回、双击重置 100%、悬停 Tooltip
local function render_mix_knob(ctx, ImGui, dl, pal, vm, item, row_id, is_strip, effectively_enabled, knob_w, row_h, mark_dirty)
  local cur_wet_pct = tonumber(item.wet_percent) or 100
  local cur_wet = (type(item.wet) == "number") and item.wet or (cur_wet_pct / 100.0)

  if not dl or not has_imgui(ImGui, "InvisibleButton") then
    -- 极端无 DrawList 环境安全回退
    if has_imgui(ImGui, "SetNextItemWidth") then
      ImGui.SetNextItemWidth(ctx, knob_w)
    end
    local chg_wet, new_wet_pct = ImGui.SliderInt(ctx, "##row_wet", cur_wet_pct, 0, 100, "%d%%")
    if chg_wet and ui._wet_edit_start[row_id] == nil then
      ui._wet_edit_start[row_id] = cur_wet
    end
    local deactivated = has_imgui(ImGui, "IsItemDeactivatedAfterEdit") and ImGui.IsItemDeactivatedAfterEdit(ctx)
    if deactivated then
      local final_pct = chg_wet and new_wet_pct or cur_wet_pct
      local start_wet = ui._wet_edit_start[row_id]
      ui._wet_edit_start[row_id] = nil
      core.set_fx_wet(vm.track, item.fx_id, final_pct / 100.0, true, start_wet)
      mark_dirty()
    elseif chg_wet then
      core.set_fx_wet(vm.track, item.fx_id, new_wet_pct / 100.0, false)
      mark_dirty()
    end
    return
  end

  ImGui.InvisibleButton(ctx, "##row_wet_knob", knob_w, row_h)

  local is_active = has_imgui(ImGui, "IsItemActive") and ImGui.IsItemActive(ctx) or false
  local is_hovered = has_imgui(ImGui, "IsItemHovered") and ImGui.IsItemHovered(ctx) or false
  local is_deactivated = has_imgui(ImGui, "IsItemDeactivated") and ImGui.IsItemDeactivated(ctx) or false

  if is_active or is_hovered then
    set_mouse_cursor(ctx, ImGui, "MouseCursor_ResizeNS")
  end

  -- 1. 双击快速重置为 100%
  local mouse_left = enum_val(rawget(ImGui, "MouseButton_Left"))
  local double_clicked = is_hovered
    and has_imgui(ImGui, "IsMouseDoubleClicked")
    and ImGui.IsMouseDoubleClicked(ctx, mouse_left)
    or false

  if double_clicked then
    local pre_wet = ui._wet_edit_start[row_id] or cur_wet
    ui._wet_ignore_drag[row_id] = true
    ui._wet_edit_start[row_id] = nil
    ui._wet_last_val[row_id] = nil
    ui._wet_dirty[row_id] = nil
    ui._wet_prev_mouse_y[row_id] = nil
    if math.abs(1.0 - pre_wet) > 1e-4 or cur_wet_pct ~= 100 then
      core.set_fx_wet(vm.track, item.fx_id, 1.0, true, pre_wet)
      mark_dirty()
    end
    cur_wet = 1.0
    cur_wet_pct = 100
  end

  -- 2. 按住鼠标上下拖拽实时调参（record_undo = false，Shift 开启 4 倍精细微调）
  if not is_active then
    ui._wet_ignore_drag[row_id] = nil
    ui._wet_prev_mouse_y[row_id] = nil
  elseif not ui._wet_ignore_drag[row_id] then
    if ui._wet_edit_start[row_id] == nil then
      ui._wet_edit_start[row_id] = cur_wet
      ui._wet_last_val[row_id] = cur_wet
      ui._wet_dirty[row_id] = false
    end

    local dy = 0.0
    if has_imgui(ImGui, "GetMouseDelta") then
      local _, m_dy = ImGui.GetMouseDelta(ctx)
      dy = tonumber(m_dy) or 0.0
    elseif has_imgui(ImGui, "GetMousePos") then
      local _, my = ImGui.GetMousePos(ctx)
      if type(my) == "number" then
        if type(ui._wet_prev_mouse_y[row_id]) == "number" then
          dy = my - ui._wet_prev_mouse_y[row_id]
        end
        ui._wet_prev_mouse_y[row_id] = my
      end
    end

    if math.abs(dy) > 0.0 then
      local sensitivity = is_shift_held(ctx, ImGui) and 460.0 or 115.0
      local prev_val = ui._wet_last_val[row_id] or cur_wet
      local next_val = math.max(0.0, math.min(1.0, prev_val - (dy / sensitivity)))
      if math.abs(next_val - prev_val) > 1e-4 then
        ui._wet_last_val[row_id] = next_val
        ui._wet_dirty[row_id] = true
        core.set_fx_wet(vm.track, item.fx_id, next_val, false)
        mark_dirty()
      end
    end

    cur_wet = ui._wet_last_val[row_id] or cur_wet
    cur_wet_pct = math.floor(cur_wet * 100.0 + 0.5)
  end

  -- 3. 松手释放：恢复拖拽前基线 pre_undo_wet_0_to_1 并记录单次干净的 Undo
  if (is_deactivated or not is_active) and ui._wet_edit_start[row_id] ~= nil then
    local start_wet = ui._wet_edit_start[row_id]
    local final_wet = ui._wet_last_val[row_id] or cur_wet
    local was_dirty = ui._wet_dirty[row_id]
    ui._wet_edit_start[row_id] = nil
    ui._wet_last_val[row_id] = nil
    ui._wet_dirty[row_id] = nil
    ui._wet_prev_mouse_y[row_id] = nil

    if was_dirty and type(start_wet) == "number" and math.abs(final_wet - start_wet) > 1e-4 then
      core.set_fx_wet(vm.track, item.fx_id, final_wet, true, start_wet)
      mark_dirty()
      cur_wet = final_wet
      cur_wet_pct = math.floor(cur_wet * 100.0 + 0.5)
    end
  end

  -- 4. ImDrawList 绘制紧凑圆弧旋钮 + 右对齐百分比读数
  if has_imgui(ImGui, "GetItemRectMin") and has_imgui(ImGui, "GetItemRectMax") then
    local x1, y1 = ImGui.GetItemRectMin(ctx)
    local x2, y2 = ImGui.GetItemRectMax(ctx)
    local cx = x1 + 10.0
    local cy = (y1 + y2) * 0.5
    local radius = 7.4
    local a_val = KNOB_ARC_MIN + cur_wet * (KNOB_ARC_MAX - KNOB_ARC_MIN)

    local arc_col = pal.knob_arc_normal
    if not effectively_enabled then
      arc_col = pal.knob_arc_bypassed
    elseif is_strip then
      arc_col = pal.knob_arc_strip
    end

    -- 悬停/激活态外环呼吸高亮，明确提示可拖拽
    if (is_hovered or is_active) and has_imgui(ImGui, "DrawList_AddCircle") then
      local ring_col = is_active and arc_col or (pal.knob_ring_hover or arc_col)
      ImGui.DrawList_AddCircle(dl, cx, cy, radius + 2.0, ring_col, 20, 1.1)
    end

    -- 旋钮圆盘底色
    if has_imgui(ImGui, "DrawList_AddCircleFilled") then
      ImGui.DrawList_AddCircleFilled(dl, cx, cy, radius - 1.3, pal.knob_bg)
    end

    -- 270 度背景弧槽
    draw_arc(ImGui, dl, cx, cy, radius, KNOB_ARC_MIN, KNOB_ARC_MAX, pal.knob_track, 2.0, 20)

    -- 有效值圆弧
    if cur_wet > 0.005 then
      draw_arc(ImGui, dl, cx, cy, radius, KNOB_ARC_MIN, a_val, arc_col, 2.3, 20)
    end

    -- 旋钮指针刻度线
    if has_imgui(ImGui, "DrawList_AddLine") then
      local p_in = 1.6
      local p_out = radius - 1.3
      local px1 = cx + math.cos(a_val) * p_in
      local py1 = cy + math.sin(a_val) * p_in
      local px2 = cx + math.cos(a_val) * p_out
      local py2 = cy + math.sin(a_val) * p_out
      local ptr_col = effectively_enabled and pal.knob_pointer or pal.row_text_bypassed
      ImGui.DrawList_AddLine(dl, px1, py1, px2, py2, ptr_col, 1.6)
    end

    -- 右侧紧凑百分比数值（右对齐至 knob 区域内，避免 "100%" 溢出撞击删除按钮）
    if has_imgui(ImGui, "DrawList_AddText") then
      local pct_str = string.format("%d%%", cur_wet_pct)
      local pct_w = calc_text_width(ctx, ImGui, pct_str)
      local line_h = has_imgui(ImGui, "GetTextLineHeight") and ImGui.GetTextLineHeight(ctx) or 13
      local text_x = math.max(x1 + 20.5, x2 - pct_w - 3.0)
      local text_y = cy - line_h * 0.5
      local text_col = pal.knob_text
      if not effectively_enabled then
        text_col = pal.row_text_bypassed
      elseif is_active or is_hovered or cur_wet_pct < 100 then
        text_col = is_strip and pal.knob_text_active or (pal.knob_text_normal_active or arc_col)
      end
      ImGui.DrawList_AddText(dl, text_x, text_y, text_col, pct_str)
    end
  end

  -- 5. 悬停或拖拽时显示精确百分比 Tooltip
  if is_hovered or is_active then
    show_tooltip(
      ctx,
      ImGui,
      string.format("MIX (干湿比): %d%%", cur_wet_pct),
      "上下拖拽调节 · 按住 Shift 微调 · 双击重置 100%"
    )
  end
end

--- 绘制紧凑的硬件风格行尾删除按钮（悬停亮柔和珊瑚红微底，无 DrawList 时回退普通按钮）
local function render_row_delete_button(ctx, ImGui, dl, pal, del_w, row_h, on_delete)
  if dl and has_imgui(ImGui, "InvisibleButton") and has_imgui(ImGui, "DrawList_AddLine") then
    local clicked = ImGui.InvisibleButton(ctx, "##row_del", del_w, row_h)
    local hovered = has_imgui(ImGui, "IsItemHovered") and ImGui.IsItemHovered(ctx) or false
    if clicked then
      on_delete()
    end
    if hovered then
      set_mouse_cursor(ctx, ImGui, "MouseCursor_Hand")
    end

    if has_imgui(ImGui, "GetItemRectMin") and has_imgui(ImGui, "GetItemRectMax") then
      local x1, y1 = ImGui.GetItemRectMin(ctx)
      local x2, y2 = ImGui.GetItemRectMax(ctx)
      local cx = (x1 + x2) * 0.5
      local cy = (y1 + y2) * 0.5

      if hovered and has_imgui(ImGui, "DrawList_AddRectFilled") then
        ImGui.DrawList_AddRectFilled(dl, x1 + 2, y1 + 3, x2 - 2, y2 - 3, pal.delete_hover_bg or 0xB9384840, 3.0)
      end

      local icon_col = hovered and (pal.delete_hover_icon or 0xFF7B89FF) or (pal.delete_icon or pal.text_disabled)
      local r = 3.4
      ImGui.DrawList_AddLine(dl, cx - r, cy - r, cx + r, cy + r, icon_col, 1.4)
      ImGui.DrawList_AddLine(dl, cx + r, cy - r, cx - r, cy + r, icon_col, 1.4)
    end

    if hovered then
      show_tooltip(ctx, ImGui, "移除此插件", "从当前轨道移除（可 Ctrl+Z 撤销）")
    end
    return
  end

  if ImGui.Button(ctx, "×##row_del", del_w, 0) then
    on_delete()
  end
end

--- 绘制单行 FX 卡片控件（含卡片底色/描边、左侧微细色条、Bypass 指示灯、裁剪截断插件名、整行无死角双向拖拽高亮、右键菜单、MIX 圆弧旋钮与快捷移除）
local function render_fx_row(ctx, ImGui, vm, item, zone, total_count, mark_dirty, pal)
  local is_strip = (zone == "strip")
  local slot_num = is_strip and item.slot or item.visual_slot
  local row_id = (item.guid and item.guid ~= "") and item.guid or (zone .. "_idx_" .. tostring(slot_num))

  local row_on = item.enabled and true or false
  local strip_master_on = (not is_strip) or (vm.strip.enabled and true or false)
  local effectively_enabled = row_on and strip_master_on

  ImGui.PushID(ctx, row_id)

  local dl = has_imgui(ImGui, "GetWindowDrawList") and ImGui.GetWindowDrawList(ctx) or nil
  local row_x, row_y = 0, 0
  if has_imgui(ImGui, "GetCursorScreenPos") then
    row_x, row_y = ImGui.GetCursorScreenPos(ctx)
  end
  local start_cursor_x = has_imgui(ImGui, "GetCursorPosX") and ImGui.GetCursorPosX(ctx) or 0
  local avail_w = has_imgui(ImGui, "GetContentRegionAvail") and ImGui.GetContentRegionAvail(ctx) or 260
  local row_w = math.max(150, avail_w)
  local frame_h = has_imgui(ImGui, "GetFrameHeight") and ImGui.GetFrameHeight(ctx) or 20
  local row_h = math.max(24, frame_h + 2)
  local row_bounds = {
    x1 = row_x,
    y1 = row_y,
    x2 = row_x + row_w,
    y2 = row_y + row_h,
  }

  -- 精确分配行内 4 段控件宽度（严格锁定在卡片内部，彻底消除长插件名或 "100%" 溢出）
  local left_pad = 5
  local led_w = 18
  local del_w = 20
  local right_pad = 2
  local pct_max_w = calc_text_width(ctx, ImGui, "100%")
  local knob_w = math.max(54, math.ceil(22 + pct_max_w + 4))
  local name_w = math.max(36, row_w - left_pad - led_w - knob_w - del_w - right_pad)

  -- 0. 单行卡片容器底色、1px 柔和描边与左侧微细强调色条
  if dl and has_imgui(ImGui, "DrawList_AddRectFilled") then
    local row_hovered = has_imgui(ImGui, "IsMouseHoveringRect")
      and ImGui.IsMouseHoveringRect(ctx, row_bounds.x1, row_bounds.y1, row_bounds.x2, row_bounds.y2)
      or false

    local bg_col = is_strip and pal.row_bg_strip or pal.row_bg_normal
    if item.is_open then
      bg_col = pal.row_bg_open
    elseif row_hovered then
      bg_col = pal.row_bg_hover
    end

    ImGui.DrawList_AddRectFilled(dl, row_bounds.x1, row_bounds.y1, row_bounds.x2, row_bounds.y2, bg_col, 4.0)

    if has_imgui(ImGui, "DrawList_AddRect") then
      local border_col = item.is_open
        and pal.row_border_open
        or (is_strip and (pal.row_border_strip or pal.border) or (pal.row_border_normal or pal.border))
      local border_thick = item.is_open and 1.25 or 1.0
      ImGui.DrawList_AddRect(dl, row_bounds.x1, row_bounds.y1, row_bounds.x2, row_bounds.y2, border_col, 4.0, 0, border_thick)
    end

    local bar_col
    if is_strip then
      bar_col = effectively_enabled and pal.strip_accent or pal.strip_accent_dim
    else
      bar_col = effectively_enabled and pal.normal_accent or pal.normal_accent_dim
    end
    ImGui.DrawList_AddRectFilled(dl, row_bounds.x1 + 0.5, row_bounds.y1 + 2.5, row_bounds.x1 + 3.5, row_bounds.y2 - 2.5, bar_col, 1.5)
  end

  -- 1. 单行独立 Bypass 指示灯（避开左侧色条）
  if has_imgui(ImGui, "SetCursorPosX") then
    ImGui.SetCursorPosX(ctx, start_cursor_x + left_pad)
  end
  render_bypass_led(ctx, ImGui, dl, pal, is_strip, row_on, effectively_enabled, led_w, row_h, function(new_en)
    core.set_fx_enabled(vm.track, item.fx_id, new_en)
    mark_dirty()
  end)
  attach_zone_drop_target(ctx, ImGui, vm, zone, slot_num, mark_dirty, pal, row_bounds)

  -- 2. 插件名称热区（零 Selectable 脏矩形、UTF-8 安全截断 + ClipRect 防溢出、点击切换悬浮窗、双向拖拽与右键菜单）
  ImGui.SameLine(ctx, 0, 0)
  local prefix = is_strip and string.format("0.%d", slot_num) or string.format("%d.", slot_num)
  local display_name = (item.name and item.name ~= "") and item.name or "(Unnamed FX)"
  local clicked_name = false
  local name_hovered = false
  local name_truncated = false

  if dl and has_imgui(ImGui, "InvisibleButton") and has_imgui(ImGui, "DrawList_AddText") then
    clicked_name = ImGui.InvisibleButton(ctx, "##row_name", name_w, row_h)
    name_hovered = has_imgui(ImGui, "IsItemHovered") and ImGui.IsItemHovered(ctx) or false
    if name_hovered and not ui._active_dnd_zone then
      set_mouse_cursor(ctx, ImGui, "MouseCursor_Hand")
    end

    if has_imgui(ImGui, "GetItemRectMin") and has_imgui(ImGui, "GetItemRectMax") then
      local nx1, ny1 = ImGui.GetItemRectMin(ctx)
      local nx2, ny2 = ImGui.GetItemRectMax(ctx)
      local line_h = has_imgui(ImGui, "GetTextLineHeight") and ImGui.GetTextLineHeight(ctx) or 13
      local text_y = (ny1 + ny2 - line_h) * 0.5

      local slot_col = effectively_enabled
        and (is_strip and pal.row_slot_strip or pal.row_slot_normal)
        or pal.row_text_bypassed
      local text_col = effectively_enabled and pal.row_text or pal.row_text_bypassed

      local prefix_w = calc_text_width(ctx, ImGui, prefix)
      local gap_after_prefix = 5.0
      local open_dot_reserve = item.is_open and 10.0 or 2.0
      local name_x = nx1 + 3.0 + prefix_w + gap_after_prefix
      local max_name_w = math.max(12, (nx2 - open_dot_reserve) - name_x)

      local suffix_tag = row_on and "" or " [旁通]"
      local fitted_name, was_trunc = fit_text_with_ellipsis(ctx, ImGui, display_name .. suffix_tag, max_name_w)
      name_truncated = was_trunc

      local can_clip = has_imgui(ImGui, "DrawList_PushClipRect") and has_imgui(ImGui, "DrawList_PopClipRect")
      if can_clip then
        ImGui.DrawList_PushClipRect(dl, nx1, ny1, nx2, ny2, true)
      end

      ImGui.DrawList_AddText(dl, nx1 + 3.0, text_y, slot_col, prefix)
      ImGui.DrawList_AddText(dl, name_x, text_y, text_col, fitted_name)

      if item.is_open and has_imgui(ImGui, "DrawList_AddCircleFilled") then
        local dot_col = is_strip and pal.strip_accent or pal.normal_accent
        ImGui.DrawList_AddCircleFilled(dl, nx2 - 5.0, (ny1 + ny2) * 0.5, 2.5, dot_col)
      end

      if can_clip then
        ImGui.DrawList_PopClipRect(dl)
      end
    end
  else
    -- 无 DrawList 回退路径
    local label = string.format("%s  %s%s", prefix, display_name, row_on and "" or " [旁通]")
    local text_col = effectively_enabled and pal.row_text or pal.row_text_bypassed
    local pushed_text = push_style_color(ctx, ImGui, "Col_Text", text_col)
    clicked_name = ImGui.Selectable(ctx, label, item.is_open and true or false, 0, name_w, 0)
    pop_style_color(ctx, ImGui, pushed_text)
    name_hovered = has_imgui(ImGui, "IsItemHovered") and ImGui.IsItemHovered(ctx) or false
  end

  if clicked_name then
    core.toggle_fx_floating_window(vm.track, item.fx_id)
    mark_dirty()
  end

  -- 2a. 区内与跨区双向拖拽源（统一使用 REAPCH_DND_FX 载荷，底层严格保护 0 号位容器本体）
  if has_imgui(ImGui, "BeginDragDropSource") and ImGui.BeginDragDropSource(ctx) then
    ui._frame_has_dnd_source = true
    ui._active_dnd_zone = zone
    ui._active_dnd_slot = slot_num
    local payload_str = string.format("%s:%d", zone, slot_num)
    ImGui.SetDragDropPayload(ctx, DND_PAYLOAD_TYPE, payload_str)
    local dnd_col = is_strip and pal.row_slot_strip or pal.row_slot_normal
    local pushed_dnd = push_style_color(ctx, ImGui, "Col_Text", dnd_col)
    ImGui.Text(ctx, string.format("%s %s %s", is_strip and "◆" or "●", prefix, display_name))
    pop_style_color(ctx, ImGui, pushed_dnd)
    ImGui.TextDisabled(ctx, "拖拽排序或跨区移入/移出")
    ImGui.EndDragDropSource(ctx)
  end

  attach_zone_drop_target(ctx, ImGui, vm, zone, slot_num, mark_dirty, pal, row_bounds)

  -- 2b. 右键快捷菜单（紧跟名称热区绑定，打开期间抑制悬停 Tooltip 防遮挡）
  local row_ctx_open = false
  if has_imgui(ImGui, "BeginPopupContextItem") and ImGui.BeginPopupContextItem(ctx, "row_ctx_menu") then
    row_ctx_open = true
    ImGui.Text(ctx, string.format("%s  %s", prefix, display_name))
    ImGui.Separator(ctx)
    if ImGui.MenuItem(ctx, item.is_open and "隐藏插件悬浮窗" or "打开插件悬浮窗") then
      core.toggle_fx_floating_window(vm.track, item.fx_id)
      mark_dirty()
    end
    if ImGui.MenuItem(ctx, row_on and "旁通此插件 (Bypass)" or "启用此插件") then
      core.set_fx_enabled(vm.track, item.fx_id, not row_on)
      mark_dirty()
    end
    local cur_pct = tonumber(item.wet_percent) or 100
    if ImGui.MenuItem(ctx, "重置干湿比为 100%", nil, false, cur_pct ~= 100) then
      local pre_wet = (type(item.wet) == "number") and item.wet or (cur_pct / 100.0)
      core.set_fx_wet(vm.track, item.fx_id, 1.0, true, pre_wet)
      mark_dirty()
    end
    ImGui.Separator(ctx)
    if ImGui.MenuItem(ctx, "上移槽位 (▲)", nil, false, slot_num > 1) then
      if is_strip then
        core.move_strip_fx(vm.track, slot_num, slot_num - 1)
      else
        core.move_normal_fx(vm.track, slot_num, slot_num - 1)
      end
      mark_dirty()
    end
    if ImGui.MenuItem(ctx, "下移槽位 (▼)", nil, false, slot_num < total_count) then
      if is_strip then
        core.move_strip_fx(vm.track, slot_num, slot_num + 1)
      else
        core.move_normal_fx(vm.track, slot_num, slot_num + 1)
      end
      mark_dirty()
    end
    if is_strip then
      if ImGui.MenuItem(ctx, "移出至常规 FX 槽 (▼)") then
        core.move_strip_fx_to_normal(vm.track, slot_num, nil)
        mark_dirty()
      end
    else
      if ImGui.MenuItem(ctx, "移入 0 号位 Channel Strip (▲)") then
        core.move_normal_fx_to_strip(vm.track, slot_num, nil)
        mark_dirty()
      end
    end
    ImGui.Separator(ctx)
    if ImGui.MenuItem(ctx, "移除此插件 (×)") then
      if is_strip then
        core.remove_strip_fx(vm.track, slot_num)
      else
        core.delete_normal_fx(vm.track, slot_num)
      end
      mark_dirty()
    end
    ImGui.EndPopup(ctx)
  end

  -- 悬停名称提示（完整插件名防截断 + 当前窗口/旁通状态；右键菜单打开或拖拽时不弹）
  if name_hovered and not row_ctx_open and not ui._active_dnd_zone then
    local status_parts = {}
    if item.is_open then
      status_parts[#status_parts + 1] = "悬浮窗已开启"
    end
    if not row_on then
      status_parts[#status_parts + 1] = "单行已旁通"
    elseif not strip_master_on then
      status_parts[#status_parts + 1] = "0 号位总旁通中"
    end
    status_parts[#status_parts + 1] = string.format("MIX %d%%", tonumber(item.wet_percent) or 100)
    if name_truncated or item.is_open or not effectively_enabled then
      show_tooltip(
        ctx,
        ImGui,
        string.format("%s  %s", prefix, display_name),
        table.concat(status_parts, " · ") .. " | 左键开关窗口 · 右键更多 · 拖拽排序"
      )
    end
  end

  -- 3. 单行紧凑圆弧 MIX (Wet/Dry 干湿比) 旋钮
  ImGui.SameLine(ctx, 0, 0)
  render_mix_knob(ctx, ImGui, dl, pal, vm, item, row_id, is_strip, effectively_enabled, knob_w, row_h, mark_dirty)
  attach_zone_drop_target(ctx, ImGui, vm, zone, slot_num, mark_dirty, pal, row_bounds)

  -- 4. 快捷移除按钮
  ImGui.SameLine(ctx, 0, 0)
  render_row_delete_button(ctx, ImGui, dl, pal, del_w, row_h, function()
    if is_strip then
      core.remove_strip_fx(vm.track, slot_num)
    else
      core.delete_normal_fx(vm.track, slot_num)
    end
    mark_dirty()
  end)
  attach_zone_drop_target(ctx, ImGui, vm, zone, slot_num, mark_dirty, pal, row_bounds)

  ImGui.PopID(ctx)
end

--- 绘制上半区紧凑总 Bypass 硬件胶囊开关 (ON / OFF)
local function render_strip_master_pill(ctx, ImGui, dl, pal, is_on, pill_w, hdr_h, on_toggle)
  if dl and has_imgui(ImGui, "InvisibleButton") and has_imgui(ImGui, "DrawList_AddRectFilled") then
    local clicked = ImGui.InvisibleButton(ctx, "##strip_master_pill", pill_w, hdr_h)
    local hovered = has_imgui(ImGui, "IsItemHovered") and ImGui.IsItemHovered(ctx) or false
    if clicked then
      on_toggle(not is_on)
    end
    if hovered then
      set_mouse_cursor(ctx, ImGui, "MouseCursor_Hand")
    end

    if has_imgui(ImGui, "GetItemRectMin") and has_imgui(ImGui, "GetItemRectMax") then
      local x1, y1 = ImGui.GetItemRectMin(ctx)
      local x2, y2 = ImGui.GetItemRectMax(ctx)
      local py1 = y1 + 3.0
      local py2 = y2 - 3.0

      local bg_col
      if is_on then
        bg_col = hovered and (pal.master_on_bg_hover or pal.strip_accent) or (pal.master_on_bg or pal.strip_accent)
      else
        bg_col = hovered and (pal.master_off_bg_hover or pal.button_hovered) or (pal.master_off_bg or pal.button)
      end
      ImGui.DrawList_AddRectFilled(dl, x1 + 1, py1, x2 - 1, py2, bg_col, 9.0)

      if has_imgui(ImGui, "DrawList_AddText") then
        local txt = is_on and "ON" or "OFF"
        local tw = calc_text_width(ctx, ImGui, txt)
        local lh = has_imgui(ImGui, "GetTextLineHeight") and ImGui.GetTextLineHeight(ctx) or 13
        local tx = (x1 + x2 - tw) * 0.5
        local ty = (py1 + py2 - lh) * 0.5
        local tcol = is_on and (pal.master_on_text or 0x16191FFF) or (pal.master_off_text or pal.text_disabled)
        ImGui.DrawList_AddText(dl, tx, ty, tcol, txt)
      end
    end

    if hovered then
      show_tooltip(
        ctx,
        ImGui,
        is_on and "0 号位 Channel Strip: 已启用 (ON)" or "0 号位 Channel Strip: 整区已旁通 (OFF)",
        "点击一键切换整条模拟链总 Bypass，用于快速 A/B 对比"
      )
    end
    return
  end

  local chg_master, new_master = ImGui.Checkbox(ctx, "启用##strip_master_enable", is_on)
  if chg_master then
    on_toggle(new_master)
  end
end

--- 绘制双区通用精致标题卡片（零 Selectable 脏框、精确动态右对齐、窄窗防重叠溢出）
local function render_zone_header(ctx, ImGui, vm, zone, title_text, count_num, pal, mark_dirty)
  local is_strip = (zone == "strip")
  local dl = has_imgui(ImGui, "GetWindowDrawList") and ImGui.GetWindowDrawList(ctx) or nil
  local start_x, start_y = 0, 0
  if has_imgui(ImGui, "GetCursorScreenPos") then
    start_x, start_y = ImGui.GetCursorScreenPos(ctx)
  end
  local start_cursor_x = has_imgui(ImGui, "GetCursorPosX") and ImGui.GetCursorPosX(ctx) or 0
  local avail_w = has_imgui(ImGui, "GetContentRegionAvail") and ImGui.GetContentRegionAvail(ctx) or 260
  local hdr_w = math.max(150, avail_w)
  local frame_h = has_imgui(ImGui, "GetFrameHeight") and ImGui.GetFrameHeight(ctx) or 20
  local hdr_h = math.max(26, frame_h + 4)
  local bounds = { x1 = start_x, y1 = start_y, x2 = start_x + hdr_w, y2 = start_y + hdr_h }

  local bg_col = is_strip and pal.strip_zone_bg or pal.normal_zone_bg
  local border_col = is_strip and pal.strip_zone_border or pal.normal_zone_border
  local accent_col = is_strip and pal.strip_accent or pal.normal_accent
  local title_col = is_strip and pal.row_slot_strip or pal.row_slot_normal

  if dl and has_imgui(ImGui, "DrawList_AddRectFilled") then
    ImGui.DrawList_AddRectFilled(dl, bounds.x1, bounds.y1, bounds.x2, bounds.y2, bg_col, 4.0)
    ImGui.DrawList_AddRectFilled(dl, bounds.x1 + 0.5, bounds.y1 + 2.5, bounds.x1 + 4.0, bounds.y2 - 2.5, accent_col, 1.5)
  end
  if dl and has_imgui(ImGui, "DrawList_AddRect") then
    ImGui.DrawList_AddRect(dl, bounds.x1, bounds.y1, bounds.x2, bounds.y2, border_col, 4.0, 0, 1.0)
  end

  local left_pad = 8
  local add_label = "+ 添加"
  local add_w = math.max(48, math.ceil(calc_text_width(ctx, ImGui, add_label) + 12))
  local show_master = is_strip and vm.strip.initialized
  local pill_w = show_master and 38 or 0
  local gap_before_mid = 2
  local gap_before_add = show_master and 4 or 2
  local right_pad = 4
  local used_right = (show_master and (gap_before_mid + pill_w) or 0) + gap_before_add + add_w + right_pad
  local title_w = math.max(40, hdr_w - left_pad - used_right)

  -- 左侧标题热区（承接拖放至本区末尾）
  if has_imgui(ImGui, "SetCursorPosX") then
    ImGui.SetCursorPosX(ctx, start_cursor_x + left_pad)
  end
  local title_display = (count_num and count_num > 0)
    and string.format("%s (%d)", title_text, count_num)
    or title_text

  if dl and has_imgui(ImGui, "InvisibleButton") and has_imgui(ImGui, "DrawList_AddText") then
    ImGui.InvisibleButton(ctx, "##" .. zone .. "_zone_hdr", title_w, hdr_h)
    local hdr_hovered = has_imgui(ImGui, "IsItemHovered") and ImGui.IsItemHovered(ctx) or false

    if has_imgui(ImGui, "GetItemRectMin") and has_imgui(ImGui, "GetItemRectMax") then
      local tx1, ty1 = ImGui.GetItemRectMin(ctx)
      local tx2, ty2 = ImGui.GetItemRectMax(ctx)
      local lh = has_imgui(ImGui, "GetTextLineHeight") and ImGui.GetTextLineHeight(ctx) or 13
      local fitted_title, was_trunc = fit_text_with_ellipsis(ctx, ImGui, title_display, math.max(16, tx2 - tx1 - 4))
      local can_clip = has_imgui(ImGui, "DrawList_PushClipRect") and has_imgui(ImGui, "DrawList_PopClipRect")
      if can_clip then
        ImGui.DrawList_PushClipRect(dl, tx1, ty1, tx2, ty2, true)
      end
      ImGui.DrawList_AddText(dl, tx1, (ty1 + ty2 - lh) * 0.5, title_col, fitted_title)
      if can_clip then
        ImGui.DrawList_PopClipRect(dl)
      end

      if hdr_hovered and was_trunc and not ui._active_dnd_zone then
        show_tooltip(ctx, ImGui, title_display, "可将插件拖拽至此标题栏追加到本区末尾")
      end
    end
  else
    local pushed_hdr = push_style_color(ctx, ImGui, "Col_Text", title_col)
    ImGui.Selectable(ctx, title_display .. "##" .. zone .. "_zone_hdr", false, 0, title_w, 0)
    pop_style_color(ctx, ImGui, pushed_hdr)
  end
  attach_zone_drop_target(ctx, ImGui, vm, zone, nil, mark_dirty, pal, bounds)

  -- 上半区总 Bypass 硬件胶囊开关
  if show_master then
    ImGui.SameLine(ctx, 0, gap_before_mid)
    render_strip_master_pill(ctx, ImGui, dl, pal, vm.strip.enabled and true or false, pill_w, hdr_h, function(new_en)
      core.set_strip_enabled(vm.track, new_en)
      mark_dirty()
    end)
    attach_zone_drop_target(ctx, ImGui, vm, zone, nil, mark_dirty, pal, bounds)
  end

  -- 右侧 "+ 添加" 按钮（垂直居中且像素级右对齐；由同行 hdr_h 控件保持行高，不额外 SetCursorPosY 规避 Dear ImGui 1.91 边界断言）
  ImGui.SameLine(ctx, 0, gap_before_add)
  local btn_y_offset = dl and 2 or 0
  local saved_y = has_imgui(ImGui, "GetCursorPosY") and ImGui.GetCursorPosY(ctx) or nil
  if saved_y and btn_y_offset > 0 and has_imgui(ImGui, "SetCursorPosY") then
    ImGui.SetCursorPosY(ctx, saved_y + btn_y_offset)
  end
  if ImGui.Button(ctx, add_label .. "##" .. zone .. "_add_fx_btn", add_w, math.max(18, hdr_h - btn_y_offset * 2)) then
    open_fx_browser_popup(ctx, ImGui, zone)
  end
end

--- 绘制顶部固定轨道信息栏与右上角 ⚙ 设置按钮（轨道名超长自动截断，绝不挤出 ⚙ 按钮）
local function render_header(ctx, ImGui, vm, settings, mark_dirty, is_docked, pal)
  local dl = has_imgui(ImGui, "GetWindowDrawList") and ImGui.GetWindowDrawList(ctx) or nil
  local start_x, start_y = 0, 0
  if has_imgui(ImGui, "GetCursorScreenPos") then
    start_x, start_y = ImGui.GetCursorScreenPos(ctx)
  end
  local start_cursor_x = has_imgui(ImGui, "GetCursorPosX") and ImGui.GetCursorPosX(ctx) or 0
  local avail_w = has_imgui(ImGui, "GetContentRegionAvail") and ImGui.GetContentRegionAvail(ctx) or 260
  local bar_w = math.max(150, avail_w)
  local frame_h = has_imgui(ImGui, "GetFrameHeight") and ImGui.GetFrameHeight(ctx) or 20
  local bar_h = math.max(26, frame_h + 4)

  if dl and has_imgui(ImGui, "DrawList_AddRectFilled") then
    ImGui.DrawList_AddRectFilled(
      dl,
      start_x,
      start_y,
      start_x + bar_w,
      start_y + bar_h,
      pal.header_bar_bg or pal.frame_bg,
      4.0
    )
    if has_imgui(ImGui, "DrawList_AddRect") then
      ImGui.DrawList_AddRect(
        dl,
        start_x,
        start_y,
        start_x + bar_w,
        start_y + bar_h,
        pal.header_bar_border or pal.border,
        4.0,
        0,
        1.0
      )
    end
  end

  local gear_w = math.max(26, math.ceil(calc_text_width(ctx, ImGui, "⚙") + 12))
  local left_pad = 6
  local right_pad = 4
  local info_w = math.max(60, bar_w - left_pad - gear_w - right_pad - 4)

  if has_imgui(ImGui, "SetCursorPosX") then
    ImGui.SetCursorPosX(ctx, start_cursor_x + left_pad)
  end

  if dl and has_imgui(ImGui, "InvisibleButton") and has_imgui(ImGui, "DrawList_AddText") then
    ImGui.InvisibleButton(ctx, "##reapch_track_info", info_w, bar_h)
    local info_hovered = has_imgui(ImGui, "IsItemHovered") and ImGui.IsItemHovered(ctx) or false
    if has_imgui(ImGui, "GetItemRectMin") and has_imgui(ImGui, "GetItemRectMax") then
      local ix1, iy1 = ImGui.GetItemRectMin(ctx)
      local ix2, iy2 = ImGui.GetItemRectMax(ctx)
      local lh = has_imgui(ImGui, "GetTextLineHeight") and ImGui.GetTextLineHeight(ctx) or 13
      local cy = (iy1 + iy2) * 0.5

      local badge_txt = "TRK"
      local badge_tw = calc_text_width(ctx, ImGui, badge_txt)
      local badge_w = badge_tw + 10
      local badge_x1 = ix1
      local badge_x2 = ix1 + badge_w
      local badge_y1 = iy1 + 4.0
      local badge_y2 = iy2 - 4.0

      if has_imgui(ImGui, "DrawList_AddRectFilled") then
        ImGui.DrawList_AddRectFilled(
          dl,
          badge_x1,
          badge_y1,
          badge_x2,
          badge_y2,
          vm.has_track and (pal.track_badge_bg or pal.header) or pal.button,
          3.0
        )
      end
      ImGui.DrawList_AddText(
        dl,
        badge_x1 + 5.0,
        cy - lh * 0.5,
        vm.has_track and (pal.track_badge_text or pal.normal_accent) or pal.text_disabled,
        badge_txt
      )

      local text_x = badge_x2 + 6.0
      local max_tw = math.max(16, ix2 - text_x - 2.0)
      local raw_track_label = vm.has_track and tostring(vm.track_name or "(未命名轨道)") or "未选中轨道"
      local fitted_track = fit_text_with_ellipsis(ctx, ImGui, raw_track_label, max_tw)

      local can_clip = has_imgui(ImGui, "DrawList_PushClipRect") and has_imgui(ImGui, "DrawList_PopClipRect")
      if can_clip then
        ImGui.DrawList_PushClipRect(dl, text_x, iy1, ix2, iy2, true)
      end
      ImGui.DrawList_AddText(
        dl,
        text_x,
        cy - lh * 0.5,
        vm.has_track and pal.text or pal.text_disabled,
        fitted_track
      )
      if can_clip then
        ImGui.DrawList_PopClipRect(dl)
      end

      if info_hovered and vm.has_track then
        local strip_cnt = vm.strip.initialized and #vm.strip.children or 0
        local norm_cnt = #vm.normal_fx
        show_tooltip(
          ctx,
          ImGui,
          "当前轨道: " .. raw_track_label,
          string.format("0 号位 Strip: %d 个插件 · 常规槽: %d 个插件", strip_cnt, norm_cnt)
        )
      end
    end
  else
    if has_imgui(ImGui, "AlignTextToFramePadding") then
      ImGui.AlignTextToFramePadding(ctx)
    end
    if vm.has_track then
      ImGui.Text(ctx, "轨道: " .. tostring(vm.track_name))
    else
      ImGui.TextDisabled(ctx, "未选中轨道")
    end
  end

  ImGui.SameLine(ctx, 0, 4)
  local btn_y_offset = dl and 2 or 0
  local saved_y = has_imgui(ImGui, "GetCursorPosY") and ImGui.GetCursorPosY(ctx) or nil
  if saved_y and btn_y_offset > 0 and has_imgui(ImGui, "SetCursorPosY") then
    ImGui.SetCursorPosY(ctx, saved_y + btn_y_offset)
  end
  if ImGui.Button(ctx, "⚙##reapch_settings_btn", gear_w, math.max(18, bar_h - btn_y_offset * 2)) then
    ImGui.OpenPopup(ctx, "reapch_settings_popup")
  end
  if has_imgui(ImGui, "IsItemHovered") and ImGui.IsItemHovered(ctx) then
    show_tooltip(ctx, ImGui, "ReaPCh 设置与停靠", "切换主题配色、一键停靠与 Auto-Snap")
  end

  if ImGui.BeginPopup(ctx, "reapch_settings_popup") then
    ImGui.Text(ctx, "Reaper ProChannel (ReaPCh) 设置")
    ImGui.Separator(ctx)

    if is_docked then
      if ImGui.Button(ctx, "脱离停靠 (恢复浮动窗口)##reapch_undock_btn") then
        ui._pending_dock_id = 0
        ImGui.CloseCurrentPopup(ctx)
      end
    else
      if ImGui.Button(ctx, "一键停靠至 REAPER Docker##reapch_dock_btn") then
        local target_dock = ui._last_dock_id
        if type(target_dock) ~= "number" or target_dock >= 0 then
          target_dock = -1
        end
        ui._pending_dock_id = target_dock
        ImGui.CloseCurrentPopup(ctx)
      end
    end
    ImGui.TextDisabled(ctx, "提示: 也可拖拽标题栏(或按住Shift)至边缘蓝框自由分栏停靠")
    ImGui.Separator(ctx)

    local chg_snap, val_snap = ImGui.Checkbox(
      ctx,
      "Auto-Snap Strip to Slot 0",
      settings.auto_snap_slot0 and true or false
    )
    if chg_snap then
      settings.auto_snap_slot0 = val_snap
      core.save_setting("auto_snap_slot0", val_snap)
      mark_dirty()
    end

    local chg_theme, val_theme = ImGui.Checkbox(
      ctx,
      "跟随 REAPER 宿主主题配色 (实验性)",
      settings.follow_host_theme and true or false
    )
    if chg_theme then
      settings.follow_host_theme = val_theme
      core.save_setting("follow_host_theme", val_theme)
      theme.clear_host_cache()
      mark_dirty()
    end

    if pal and pal.mode then
      local mode_desc = "Studio Dark (默认独立深色)"
      if pal.mode == "host_light" then
        mode_desc = pal.host_accent_detected
          and "宿主浅色自适应 (已承接宿主强调色 + 对比度保护)"
          or "宿主浅色自适应 (已启用 WCAG 对比度保护)"
      elseif pal.mode == "host_dark" then
        mode_desc = pal.host_accent_detected
          and "宿主深色自适应 (已承接宿主强调色 + 对比度保护)"
          or "宿主深色自适应 (已启用 WCAG 对比度保护)"
      end
      ImGui.TextDisabled(ctx, "当前视觉模式: " .. mode_desc)
    end

    ImGui.EndPopup(ctx)
  end
end

--- 绘制 MCP 手滑偏离提示条卡片与一键归位按钮
local function render_displaced_warning_card(ctx, ImGui, vm, mark_dirty, pal)
  local dl = has_imgui(ImGui, "GetWindowDrawList") and ImGui.GetWindowDrawList(ctx) or nil
  local wx, wy = 0, 0
  if has_imgui(ImGui, "GetCursorScreenPos") then
    wx, wy = ImGui.GetCursorScreenPos(ctx)
  end
  local start_cursor_x = has_imgui(ImGui, "GetCursorPosX") and ImGui.GetCursorPosX(ctx) or 0
  local avail_w = has_imgui(ImGui, "GetContentRegionAvail") and ImGui.GetContentRegionAvail(ctx) or 260
  local card_w = math.max(150, avail_w)
  local frame_h = has_imgui(ImGui, "GetFrameHeight") and ImGui.GetFrameHeight(ctx) or 20
  local card_h = math.max(26, frame_h + 4)

  if dl and has_imgui(ImGui, "DrawList_AddRectFilled") then
    ImGui.DrawList_AddRectFilled(dl, wx, wy, wx + card_w, wy + card_h, pal.warning_bg, 4.0)
    ImGui.DrawList_AddRectFilled(dl, wx + 0.5, wy + 2.5, wx + 3.5, wy + card_h - 2.5, pal.warning_border, 1.5)
    if has_imgui(ImGui, "DrawList_AddRect") then
      ImGui.DrawList_AddRect(dl, wx, wy, wx + card_w, wy + card_h, pal.warning_border, 4.0, 0, 1.0)
    end
  end

  local snap_label = "一键归位"
  local snap_w = math.max(58, math.ceil(calc_text_width(ctx, ImGui, snap_label) + 12))
  local left_pad = 8
  local right_pad = 4
  local msg_w = math.max(40, card_w - left_pad - snap_w - right_pad - 4)
  local warn_msg = string.format("⚠ Strip 偏离至 #%d", tonumber(vm.strip.displaced_pos) or 0)

  if has_imgui(ImGui, "SetCursorPosX") then
    ImGui.SetCursorPosX(ctx, start_cursor_x + left_pad)
  end

  if dl and has_imgui(ImGui, "InvisibleButton") and has_imgui(ImGui, "DrawList_AddText") then
    ImGui.InvisibleButton(ctx, "##reapch_warn_text", msg_w, card_h)
    local warn_hovered = has_imgui(ImGui, "IsItemHovered") and ImGui.IsItemHovered(ctx) or false
    if has_imgui(ImGui, "GetItemRectMin") and has_imgui(ImGui, "GetItemRectMax") then
      local mx1, my1 = ImGui.GetItemRectMin(ctx)
      local mx2, my2 = ImGui.GetItemRectMax(ctx)
      local lh = has_imgui(ImGui, "GetTextLineHeight") and ImGui.GetTextLineHeight(ctx) or 13
      local fitted_warn = fit_text_with_ellipsis(ctx, ImGui, warn_msg, math.max(20, mx2 - mx1 - 2))
      ImGui.DrawList_AddText(dl, mx1, (my1 + my2 - lh) * 0.5, pal.warning_text, fitted_warn)
    end
    if warn_hovered then
      show_tooltip(
        ctx,
        ImGui,
        string.format("⚠ Strip 容器不在信号链最前端（当前位置 #%d）", tonumber(vm.strip.displaced_pos) or 0),
        "点击右侧 [一键归位] 将 0 号位容器移回顶层最前端"
      )
    end
  else
    local pushed_warn = push_style_color(ctx, ImGui, "Col_Text", pal.warning_text)
    ImGui.Text(ctx, warn_msg)
    pop_style_color(ctx, ImGui, pushed_warn)
  end

  ImGui.SameLine(ctx, 0, 4)
  local btn_y_offset = dl and 2 or 0
  local saved_y = has_imgui(ImGui, "GetCursorPosY") and ImGui.GetCursorPosY(ctx) or nil
  if saved_y and btn_y_offset > 0 and has_imgui(ImGui, "SetCursorPosY") then
    ImGui.SetCursorPosY(ctx, saved_y + btn_y_offset)
  end
  local snap_text = theme.on_accent_text(pal.warning_border)
  local pushed = 0
  pushed = pushed + push_style_color(ctx, ImGui, "Col_Button", pal.warning_border)
  pushed = pushed + push_style_color(ctx, ImGui, "Col_ButtonHovered", theme.blend_rgba(pal.warning_border, 0xFFFFFFFF, 0.14))
  pushed = pushed + push_style_color(ctx, ImGui, "Col_Text", snap_text)
  if ImGui.Button(ctx, snap_label .. "##snap_strip_btn", snap_w, math.max(18, card_h - btn_y_offset * 2)) then
    core.snap_strip_to_top(vm.track)
    mark_dirty()
  end
  pop_style_color(ctx, ImGui, pushed)
end

--- 绘制区域底部柔和追加/拖放条（静态时低调紧凑，拖拽过程中高亮变身为清晰 Drop Zone）
local function render_zone_tail_drop(ctx, ImGui, vm, zone, idle_text, pal, mark_dirty)
  local is_dragging = (ui._active_dnd_zone ~= nil)
  local dl = has_imgui(ImGui, "GetWindowDrawList") and ImGui.GetWindowDrawList(ctx) or nil
  local avail_w = has_imgui(ImGui, "GetContentRegionAvail") and ImGui.GetContentRegionAvail(ctx) or 260
  local tail_w = math.max(150, avail_w)
  local tail_h = is_dragging and 24 or 20

  if dl and has_imgui(ImGui, "InvisibleButton") and has_imgui(ImGui, "DrawList_AddText") then
    local clicked = ImGui.InvisibleButton(ctx, "##" .. zone .. "_tail_drop", tail_w, tail_h)
    local hovered = has_imgui(ImGui, "IsItemHovered") and ImGui.IsItemHovered(ctx) or false
    if hovered and not is_dragging then
      set_mouse_cursor(ctx, ImGui, "MouseCursor_Hand")
    end

    local bounds = nil
    if has_imgui(ImGui, "GetItemRectMin") and has_imgui(ImGui, "GetItemRectMax") then
      local x1, y1 = ImGui.GetItemRectMin(ctx)
      local x2, y2 = ImGui.GetItemRectMax(ctx)
      bounds = { x1 = x1, y1 = y1, x2 = x2, y2 = y2 }

      if is_dragging then
        if has_imgui(ImGui, "DrawList_AddRectFilled") then
          ImGui.DrawList_AddRectFilled(dl, x1, y1, x2, y2, pal.drop_zone_bg or pal.drag_target_fill, 4.0)
        end
        if has_imgui(ImGui, "DrawList_AddRect") then
          ImGui.DrawList_AddRect(dl, x1, y1, x2, y2, pal.drop_zone_border or pal.drag_insert_line, 4.0, 0, 1.0)
        end
      elseif hovered and has_imgui(ImGui, "DrawList_AddRectFilled") then
        ImGui.DrawList_AddRectFilled(dl, x1, y1, x2, y2, pal.row_bg_hover, 3.0)
      end

      local label = is_dragging and "↓ 松手追加至此区末尾" or idle_text
      local lh = has_imgui(ImGui, "GetTextLineHeight") and ImGui.GetTextLineHeight(ctx) or 13
      local fitted = fit_text_with_ellipsis(ctx, ImGui, label, math.max(30, x2 - x1 - 12))
      local lw = calc_text_width(ctx, ImGui, fitted)
      local tx = is_dragging and ((x1 + x2 - lw) * 0.5) or (x1 + 8.0)
      local col = is_dragging and pal.drag_insert_line or (hovered and pal.text or pal.text_disabled)
      ImGui.DrawList_AddText(dl, tx, (y1 + y2 - lh) * 0.5, col, fitted)
    end

    if clicked then
      open_fx_browser_popup(ctx, ImGui, zone)
    end
    attach_zone_drop_target(ctx, ImGui, vm, zone, nil, mark_dirty, pal, bounds)
    return
  end

  local pushed_tail = push_style_color(ctx, ImGui, "Col_Text", pal.text_disabled)
  local clicked_tail = ImGui.Selectable(ctx, idle_text .. "##" .. zone .. "_tail_drop", false)
  pop_style_color(ctx, ImGui, pushed_tail)
  if clicked_tail then
    open_fx_browser_popup(ctx, ImGui, zone)
  end
  attach_zone_drop_target(ctx, ImGui, vm, zone, nil, mark_dirty, pal)
end

--- 绘制上半区：0 号位 · Channel Strip（音色塑形区）
local function render_upper_strip_zone(ctx, ImGui, vm, mark_dirty, pal)
  local child_cnt = vm.strip.initialized and #vm.strip.children or 0
  render_zone_header(ctx, ImGui, vm, "strip", "◆ 0 号位 · Channel Strip", child_cnt, pal, mark_dirty)

  -- MCP 手滑偏离提示条与一键归位
  if vm.strip.initialized and vm.strip.is_displaced then
    render_displaced_warning_card(ctx, ImGui, vm, mark_dirty, pal)
  end

  if not vm.strip.initialized then
    local avail_w = has_imgui(ImGui, "GetContentRegionAvail") and ImGui.GetContentRegionAvail(ctx) or 260
    local init_w = math.max(140, avail_w)
    if ImGui.Button(ctx, "+ 初始化 0 号位 Channel Strip##init_strip_btn", init_w, 26) then
      core.init_strip_container(vm.track)
      mark_dirty()
    end
    attach_zone_drop_target(ctx, ImGui, vm, "strip", nil, mark_dirty, pal)
    ImGui.TextDisabled(ctx, "或点击 [+ 添加] / 直接拖入下方常规插件")
    attach_zone_drop_target(ctx, ImGui, vm, "strip", nil, mark_dirty, pal)
    return
  end

  if #vm.strip.children == 0 then
    render_zone_tail_drop(ctx, ImGui, vm, "strip", "+ 空容器 · 点击添加或拖入下方插件", pal, mark_dirty)
    return
  end

  local total_children = #vm.strip.children
  for _, child in ipairs(vm.strip.children) do
    render_fx_row(ctx, ImGui, vm, child, "strip", total_children, mark_dirty, pal)
  end

  render_zone_tail_drop(ctx, ImGui, vm, "strip", "+ 添加 / 拖放至 Strip 末尾", pal, mark_dirty)
end

--- 绘制下半区：常规 FX 槽（视觉从 1 号位起）
local function render_lower_normal_zone(ctx, ImGui, vm, mark_dirty, pal)
  ImGui.Spacing(ctx)
  render_zone_header(ctx, ImGui, vm, "normal", "● 常规 FX 槽 (1..N)", #vm.normal_fx, pal, mark_dirty)

  if #vm.normal_fx == 0 then
    render_zone_tail_drop(ctx, ImGui, vm, "normal", "+ 无常规插件 · 点击添加或拖入上方插件", pal, mark_dirty)
    return
  end

  local total_normal = #vm.normal_fx
  for _, fx in ipairs(vm.normal_fx) do
    render_fx_row(ctx, ImGui, vm, fx, "normal", total_normal, mark_dirty, pal)
  end

  render_zone_tail_drop(ctx, ImGui, vm, "normal", "+ 添加 / 拖放至常规槽末尾", pal, mark_dirty)
end

--- 主界面帧绘制入口
--- @param ctx any ReaImGui Context
--- @param ImGui table ReaImGui API 表
--- @param vm table core.build_view_model 生成的视图模型
--- @param settings table 配置表
--- @param on_dirty function 触发视图模型立即刷新的回调
--- @return boolean open 窗口是否保持打开
function ui.draw(ctx, ImGui, vm, settings, on_dirty)
  local function mark_dirty()
    if type(on_dirty) == "function" then
      on_dirty()
    end
  end

  -- 轨道切换时自动清理单行 MIX 旋钮的临时拖拽状态，防止跨轨脏态残留
  local cur_track = vm and vm.track or nil
  if cur_track ~= ui._last_track_ptr then
    clear_wet_edit_state()
    ui._last_track_ptr = cur_track
  end

  local cond_first_use = enum_val(rawget(ImGui, "Cond_FirstUseEver"))
  ImGui.SetNextWindowSize(
    ctx,
    theme.DEFAULT_WINDOW_WIDTH,
    theme.DEFAULT_WINDOW_HEIGHT,
    cond_first_use
  )

  if ui._pending_dock_id ~= nil and has_imgui(ImGui, "SetNextWindowDockID") then
    ImGui.SetNextWindowDockID(ctx, ui._pending_dock_id)
    ui._pending_dock_id = nil
  end

  local col_cnt, var_cnt = theme.push(ctx, ImGui, settings)
  local pal = theme.get_palette(settings)
  ui._frame_has_dnd_source = false
  local window_flags = enum_val(rawget(ImGui, "WindowFlags_None"))
  local visible, open = ImGui.Begin(ctx, "Reaper ProChannel", true, window_flags)

  if visible then
    local is_docked = false
    if has_imgui(ImGui, "IsWindowDocked") then
      is_docked = ImGui.IsWindowDocked(ctx) and true or false
    end
    if is_docked and has_imgui(ImGui, "GetWindowDockID") then
      local cur_dock_id = ImGui.GetWindowDockID(ctx)
      if type(cur_dock_id) == "number" and cur_dock_id < 0 then
        ui._last_dock_id = cur_dock_id
      end
    end

    -- 1. 顶部固定吸顶轨道栏（不随下方双区列表滚动消失）
    render_header(ctx, ImGui, vm, settings, mark_dirty, is_docked, pal)
    ImGui.Spacing(ctx)

    -- 2. 下方双区滚动区（透明无边框 Child，适配 Split Dock 任意压缩高度）
    if has_imgui(ImGui, "BeginChild") and has_imgui(ImGui, "EndChild") then
      local pushed_body_bg = push_style_color(ctx, ImGui, "Col_ChildBg", 0x00000000)
      local body_visible = ImGui.BeginChild(ctx, "##reapch_body_scroll", 0, 0)
      pop_style_color(ctx, ImGui, pushed_body_bg)

      if body_visible then
        if not vm.has_track then
          ImGui.Spacing(ctx)
          ImGui.TextDisabled(ctx, "请在 REAPER 中选中一条轨道以查看双区插件。")
        else
          render_upper_strip_zone(ctx, ImGui, vm, mark_dirty, pal)
          render_lower_normal_zone(ctx, ImGui, vm, mark_dirty, pal)
        end
        -- ReaImGui 0.9 / 0.10 规范：仅在 BeginChild 返回 true 时调用 EndChild
        ImGui.EndChild(ctx)
      end
    else
      -- 极端无 BeginChild 环境回退直接渲染
      if not vm.has_track then
        ImGui.Spacing(ctx)
        ImGui.TextDisabled(ctx, "请在 REAPER 中选中一条轨道以查看双区插件。")
      else
        render_upper_strip_zone(ctx, ImGui, vm, mark_dirty, pal)
        render_lower_normal_zone(ctx, ImGui, vm, mark_dirty, pal)
      end
    end

    -- 在顶层主窗口 ID 栈层级统一响应插件弹窗打开请求，与 BeginPopup 作用域 100% 一致
    if ui._pending_open_fx_browser then
      ui._pending_open_fx_browser = false
      ImGui.OpenPopup(ctx, "reapch_fx_browser_popup")
    end
    render_fx_browser_popup(ctx, ImGui, vm, mark_dirty, pal)

    -- 注意：ReaImGui 0.9 / 0.10 规范要求仅在 ImGui.Begin 返回 visible == true 时调用 ImGui.End
    ImGui.End(ctx)
  end

  if not ui._frame_has_dnd_source then
    ui._active_dnd_zone = nil
    ui._active_dnd_slot = nil
  end

  theme.pop(ctx, ImGui, col_cnt, var_cnt)
  return open
end

return ui
