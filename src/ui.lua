-- src/ui.lua
-- Reaper ProChannel (ReaPCh) — 薄渲染层 (v0.2.0 Studio Dark / 宿主自适应视觉体系 + MIX 圆弧旋钮)
-- 职责：消费 core.lua 输出的双区视图模型，绘制可停靠双区卡片面板、双区独立 + 插件分组搜索弹窗（默认过滤 Synth 乐器、支持 REAPER 原生与自定义分组）、
--       单行硬件感 Bypass 指示灯、单行 ImDrawList 圆弧 MIX (Wet/Dry) 旋钮、区内与跨区双向拖拽高亮插入线反馈、偏离提示条与右上角设置菜单。
-- 说明：严格保留 REAPER / ReaImGui 原生 Docking 与 Split Dock 特性；所有可选 ImGui API 一律通过 rawget 安全探测。

local core = require("core")
local theme = require("theme")

local DND_PAYLOAD_TYPE = "REAPCH_DND_FX"
local KNOB_ARC_MIN = 0.75 * math.pi  -- 135 deg (7:30 位置)
local KNOB_ARC_MAX = 2.25 * math.pi  -- 405 deg (4:30 位置，顺时针跨度 270 deg)

local ui = {
  _pending_dock_id = nil,
  _last_dock_id = -1,
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
  local segs = segments or 18
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

local function open_fx_browser_popup(ctx, ImGui, zone)
  ui._browser_target_zone = (zone == "normal") and "normal" or "strip"
  ui._focus_search_input = true
  ImGui.OpenPopup(ctx, "reapch_fx_browser_popup")
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
--- @param vm table 视图模型
--- @param target_zone string "strip" | "normal"
--- @param target_slot number|nil 目标槽位（nil 表示拖至区域标题或空白处，追加至该区末尾）
--- @param payload string 拖拽载荷 ("strip:N" | "normal:N")
--- @param mark_dirty function 状态刷新回调
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
      ImGui.DrawList_AddRect(dl, x1, y1, x2, y2, pal.drag_insert_line, 4.0, 0, 1.2)
    end
  elseif src_zone == target_zone and type(src_slot) == "number" and src_slot < target_slot then
    line_y = y2
  end

  if has_imgui(ImGui, "DrawList_AddLine") then
    ImGui.DrawList_AddLine(dl, x1 + 4, line_y, x2 - 4, line_y, pal.drag_insert_line, 2.5)
  end
  if has_imgui(ImGui, "DrawList_AddCircleFilled") then
    ImGui.DrawList_AddCircleFilled(dl, x1 + 5, line_y, 3.2, pal.drag_insert_line)
    ImGui.DrawList_AddCircleFilled(dl, x2 - 5, line_y, 3.2, pal.drag_insert_line)
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
local function render_fx_browser_popup(ctx, ImGui, vm, mark_dirty)
  if not ImGui.BeginPopup(ctx, "reapch_fx_browser_popup") then
    return
  end

  if not vm.has_track or not vm.track then
    ImGui.TextDisabled(ctx, "请先在 REAPER 中选中一条轨道")
    ImGui.EndPopup(ctx)
    return
  end

  if ui._browser_target_zone == "strip" then
    ImGui.Text(ctx, "添加插件至: ◆ 0 号位 · Channel Strip")
  else
    ImGui.Text(ctx, "添加插件至: ● 常规 FX 槽 (1..N)")
  end
  ImGui.Separator(ctx)

  if ui._focus_search_input and has_imgui(ImGui, "SetKeyboardFocusHere") then
    ImGui.SetKeyboardFocusHere(ctx)
    ui._focus_search_input = false
  end

  if has_imgui(ImGui, "SetNextItemWidth") then
    ImGui.SetNextItemWidth(ctx, 220)
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
  if ImGui.Button(ctx, "清空##reapch_clear_search") then
    ui._fx_search_query = ""
    ui._search_query_just_changed = false
  end

  ImGui.SameLine(ctx)
  if ImGui.Button(ctx, "刷新##reapch_refresh_fx_cache") then
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
    if has_imgui(ImGui, "SetNextItemWidth") then
      ImGui.SetNextItemWidth(ctx, 200)
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
    if ImGui.Button(ctx, "新建分组##reapch_create_cgrp_btn") then
      local ok_add = core.add_custom_fx_group(ui._new_custom_group_name)
      if ok_add then
        ui._new_custom_group_name = ""
      end
    end
    ImGui.TextDisabled(ctx, "提示: 右键下方任意插件可加入/移出自定义分组；也自动读取 REAPER reaper-fxfolders.ini")
  end

  -- 分组维度切换栏
  local modes = {
    { id = "category", label = "分类" },
    { id = "custom", label = "自定义/文件夹" },
    { id = "developer", label = "厂商" },
    { id = "format", label = "格式" },
    { id = "flat", label = "平铺" },
  }
  ImGui.TextDisabled(ctx, "分组:")
  for _, m in ipairs(modes) do
    ImGui.SameLine(ctx)
    local is_active = (ui._fx_group_mode == m.id)
    local btn_text = is_active and string.format("[%s]##gmode_%s", m.label, m.id) or string.format("%s##gmode_%s", m.label, m.id)
    if ImGui.Button(ctx, btn_text) then
      ui._fx_group_mode = m.id
    end
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
  local list_visible = ImGui.BeginChild(ctx, "reapch_fx_browser_list", 360, 260)
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
local function render_bypass_led(ctx, ImGui, dl, pal, is_strip, row_on, effectively_enabled, row_h, on_toggle)
  if dl and has_imgui(ImGui, "InvisibleButton") and has_imgui(ImGui, "DrawList_AddCircleFilled") then
    local clicked = ImGui.InvisibleButton(ctx, "##row_bypass", 20, row_h)
    local hovered = has_imgui(ImGui, "IsItemHovered") and ImGui.IsItemHovered(ctx) or false
    if clicked then
      on_toggle(not row_on)
    end

    if has_imgui(ImGui, "GetItemRectMin") and has_imgui(ImGui, "GetItemRectMax") then
      local x1, y1 = ImGui.GetItemRectMin(ctx)
      local _, y2 = ImGui.GetItemRectMax(ctx)
      local cx = x1 + 11.0
      local cy = (y1 + y2) * 0.5

      -- 灯座底盘
      ImGui.DrawList_AddCircleFilled(dl, cx, cy, 5.2, pal.bypass_socket)

      if row_on then
        local glow_col = is_strip and pal.bypass_glow_strip or pal.bypass_glow_normal
        local core_col = is_strip and pal.bypass_on_strip or pal.bypass_on_normal
        if not effectively_enabled then
          core_col = theme.with_alpha(core_col, 140)
        else
          ImGui.DrawList_AddCircleFilled(dl, cx, cy, 6.6, glow_col)
        end
        ImGui.DrawList_AddCircleFilled(dl, cx, cy, 3.8, core_col)
      else
        ImGui.DrawList_AddCircleFilled(dl, cx, cy, 3.3, pal.bypass_off)
      end

      if hovered and has_imgui(ImGui, "DrawList_AddCircle") then
        local ring_col = is_strip and pal.strip_accent or pal.normal_accent
        ImGui.DrawList_AddCircle(dl, cx, cy, 6.2, ring_col, 0, 1.2)
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
local function render_mix_knob(ctx, ImGui, dl, pal, vm, item, row_id, is_strip, effectively_enabled, row_h, mark_dirty)
  local cur_wet_pct = tonumber(item.wet_percent) or 100
  local cur_wet = (type(item.wet) == "number") and item.wet or (cur_wet_pct / 100.0)

  if not dl or not has_imgui(ImGui, "InvisibleButton") then
    -- 极端无 DrawList 环境安全回退
    if has_imgui(ImGui, "SetNextItemWidth") then
      ImGui.SetNextItemWidth(ctx, 48)
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

  local knob_w = 48
  ImGui.InvisibleButton(ctx, "##row_wet_knob", knob_w, row_h)

  local is_active = has_imgui(ImGui, "IsItemActive") and ImGui.IsItemActive(ctx) or false
  local is_hovered = has_imgui(ImGui, "IsItemHovered") and ImGui.IsItemHovered(ctx) or false
  local is_deactivated = has_imgui(ImGui, "IsItemDeactivated") and ImGui.IsItemDeactivated(ctx) or false

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

  -- 4. ImDrawList 绘制紧凑圆弧旋钮 + 百分比读数
  if has_imgui(ImGui, "GetItemRectMin") and has_imgui(ImGui, "GetItemRectMax") then
    local x1, y1 = ImGui.GetItemRectMin(ctx)
    local _, y2 = ImGui.GetItemRectMax(ctx)
    local cx = x1 + 9.5
    local cy = (y1 + y2) * 0.5
    local radius = 7.4
    local a_val = KNOB_ARC_MIN + cur_wet * (KNOB_ARC_MAX - KNOB_ARC_MIN)

    -- 旋钮圆盘底色
    if has_imgui(ImGui, "DrawList_AddCircleFilled") then
      ImGui.DrawList_AddCircleFilled(dl, cx, cy, radius - 1.2, pal.knob_bg)
    end

    -- 270 度背景弧槽
    draw_arc(ImGui, dl, cx, cy, radius, KNOB_ARC_MIN, KNOB_ARC_MAX, pal.knob_track, 2.0, 18)

    -- 有效值圆弧
    local arc_col = pal.knob_arc_normal
    if not effectively_enabled then
      arc_col = pal.knob_arc_bypassed
    elseif is_strip then
      arc_col = pal.knob_arc_strip
    end
    if cur_wet > 0.005 then
      draw_arc(ImGui, dl, cx, cy, radius, KNOB_ARC_MIN, a_val, arc_col, 2.3, 18)
    end

    -- 旋钮指针刻度线
    if has_imgui(ImGui, "DrawList_AddLine") then
      local p_in = 1.5
      local p_out = radius - 1.2
      local px1 = cx + math.cos(a_val) * p_in
      local py1 = cy + math.sin(a_val) * p_in
      local px2 = cx + math.cos(a_val) * p_out
      local py2 = cy + math.sin(a_val) * p_out
      local ptr_col = effectively_enabled and pal.knob_pointer or pal.row_text_bypassed
      ImGui.DrawList_AddLine(dl, px1, py1, px2, py2, ptr_col, 1.5)
    end

    -- 右侧紧凑百分比数值
    if has_imgui(ImGui, "DrawList_AddText") then
      local line_h = has_imgui(ImGui, "GetTextLineHeight") and ImGui.GetTextLineHeight(ctx) or 13
      local text_x = x1 + 20.0
      local text_y = cy - line_h * 0.5
      local text_col = pal.knob_text
      if not effectively_enabled then
        text_col = pal.row_text_bypassed
      elseif is_active or is_hovered or cur_wet_pct < 100 then
        text_col = is_strip and pal.knob_text_active or arc_col
      end
      ImGui.DrawList_AddText(dl, text_x, text_y, text_col, string.format("%d%%", cur_wet_pct))
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

--- 绘制单行 FX 卡片控件（含卡片底色、左侧区域微细色条、Bypass 指示灯、悬浮窗切换、双向拖拽高亮、右键菜单、MIX 圆弧旋钮与快捷移除）
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
  local row_w = has_imgui(ImGui, "GetContentRegionAvail") and ImGui.GetContentRegionAvail(ctx) or 260
  local row_h = has_imgui(ImGui, "GetFrameHeight") and math.max(22, ImGui.GetFrameHeight(ctx)) or 22
  local row_bounds = {
    x1 = row_x,
    y1 = row_y,
    x2 = row_x + row_w,
    y2 = row_y + row_h,
  }

  -- 0. 单行卡片容器底色与左侧微细色条（清晰区分 0 号位 Channel Strip 与常规 FX 槽）
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

    if item.is_open and has_imgui(ImGui, "DrawList_AddRect") then
      ImGui.DrawList_AddRect(dl, row_bounds.x1, row_bounds.y1, row_bounds.x2, row_bounds.y2, pal.row_border_open, 4.0, 0, 1.0)
    end

    local bar_col
    if is_strip then
      bar_col = effectively_enabled and pal.strip_accent or pal.strip_accent_dim
    else
      bar_col = effectively_enabled and pal.normal_accent or pal.normal_accent_dim
    end
    ImGui.DrawList_AddRectFilled(dl, row_bounds.x1, row_bounds.y1 + 2, row_bounds.x1 + 3.2, row_bounds.y2 - 2, bar_col, 1.5)
  end

  -- 1. 单行独立 Bypass 指示灯
  render_bypass_led(ctx, ImGui, dl, pal, is_strip, row_on, effectively_enabled, row_h, function(new_en)
    core.set_fx_enabled(vm.track, item.fx_id, new_en)
    mark_dirty()
  end)

  -- 2. 插件名称（点击切换悬浮窗、支持区内排序及上下跨区拖拽、旁通态低对比度文字、右键上下文菜单）
  ImGui.SameLine(ctx)
  if has_imgui(ImGui, "AlignTextToFramePadding") then
    ImGui.AlignTextToFramePadding(ctx)
  end

  local prefix = is_strip and string.format("0.%d", slot_num) or string.format("%d.", slot_num)
  local display_name = (item.name and item.name ~= "") and item.name or "(Unnamed FX)"
  local label = string.format(
    "%s  %s%s",
    prefix,
    display_name,
    row_on and "" or " [旁通]"
  )

  local avail_after_led = has_imgui(ImGui, "GetContentRegionAvail") and ImGui.GetContentRegionAvail(ctx) or 180
  local right_controls_w = 82 -- 预留右侧 48px MIX 旋钮 + 20px 移除按钮 + 间距与卡片右内边距
  local name_w = math.max(52, avail_after_led - right_controls_w)

  local text_col = effectively_enabled and pal.row_text or pal.row_text_bypassed
  local pushed_text = push_style_color(ctx, ImGui, "Col_Text", text_col)
  local clicked_name = ImGui.Selectable(ctx, label, item.is_open and true or false, 0, name_w, 0)
  pop_style_color(ctx, ImGui, pushed_text)

  if clicked_name then
    core.toggle_fx_floating_window(vm.track, item.fx_id)
    mark_dirty()
  end

  -- 2a. 区内与跨区双向拖拽（统一使用 REAPCH_DND_FX 载荷，底层严格保护 0 号位容器本体）
  if has_imgui(ImGui, "BeginDragDropSource") and ImGui.BeginDragDropSource(ctx) then
    ui._frame_has_dnd_source = true
    ui._active_dnd_zone = zone
    ui._active_dnd_slot = slot_num
    local payload_str = string.format("%s:%d", zone, slot_num)
    ImGui.SetDragDropPayload(ctx, DND_PAYLOAD_TYPE, payload_str)
    ImGui.Text(ctx, string.format("移动 %s %s", prefix, display_name))
    ImGui.EndDragDropSource(ctx)
  end

  attach_zone_drop_target(ctx, ImGui, vm, zone, slot_num, mark_dirty, pal, row_bounds)

  -- 2b. 右键快捷菜单（悬浮窗/旁通/干湿比重置/区内上下移动/跨区移入移出/移除）
  if has_imgui(ImGui, "BeginPopupContextItem") and ImGui.BeginPopupContextItem(ctx, "row_ctx_menu") then
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

  -- 3. 单行紧凑圆弧 MIX (Wet/Dry 干湿比) 旋钮
  ImGui.SameLine(ctx)
  render_mix_knob(ctx, ImGui, dl, pal, vm, item, row_id, is_strip, effectively_enabled, row_h, mark_dirty)

  -- 4. 快捷移除按钮
  ImGui.SameLine(ctx)
  if ImGui.Button(ctx, "×##row_del") then
    if is_strip then
      core.remove_strip_fx(vm.track, slot_num)
    else
      core.delete_normal_fx(vm.track, slot_num)
    end
    mark_dirty()
  end

  ImGui.PopID(ctx)
end

--- 绘制区域标题卡片背景与左侧强调色竖条
local function draw_zone_header_card(ctx, ImGui, bg_col, border_col, accent_col)
  if not has_imgui(ImGui, "GetWindowDrawList") or not has_imgui(ImGui, "GetCursorScreenPos") then
    return nil
  end
  local dl = ImGui.GetWindowDrawList(ctx)
  if not dl then
    return nil
  end
  local x, y = ImGui.GetCursorScreenPos(ctx)
  local w = has_imgui(ImGui, "GetContentRegionAvail") and ImGui.GetContentRegionAvail(ctx) or 260
  local h = has_imgui(ImGui, "GetFrameHeight") and math.max(22, ImGui.GetFrameHeight(ctx)) or 22
  local bounds = { x1 = x, y1 = y, x2 = x + w, y2 = y + h }

  if has_imgui(ImGui, "DrawList_AddRectFilled") then
    ImGui.DrawList_AddRectFilled(dl, bounds.x1, bounds.y1, bounds.x2, bounds.y2, bg_col, 4.0)
    ImGui.DrawList_AddRectFilled(dl, bounds.x1, bounds.y1 + 2, bounds.x1 + 3.5, bounds.y2 - 2, accent_col, 1.5)
  end
  if has_imgui(ImGui, "DrawList_AddRect") then
    ImGui.DrawList_AddRect(dl, bounds.x1, bounds.y1, bounds.x2, bounds.y2, border_col, 4.0, 0, 1.0)
  end
  if has_imgui(ImGui, "SetCursorPosX") and has_imgui(ImGui, "GetCursorPosX") then
    ImGui.SetCursorPosX(ctx, ImGui.GetCursorPosX(ctx) + 7)
  end
  return bounds
end

--- 绘制顶部轨道信息栏与右上角 ⚙ 设置按钮
local function render_header(ctx, ImGui, vm, settings, mark_dirty, is_docked, pal)
  if has_imgui(ImGui, "AlignTextToFramePadding") then
    ImGui.AlignTextToFramePadding(ctx)
  end
  if vm.has_track then
    ImGui.Text(ctx, "轨道: " .. tostring(vm.track_name))
  else
    ImGui.TextDisabled(ctx, "未选中轨道")
  end

  ImGui.SameLine(ctx)
  local avail_w = ImGui.GetContentRegionAvail(ctx)
  if avail_w and avail_w > 28 then
    ImGui.SetCursorPosX(ctx, ImGui.GetCursorPosX(ctx) + avail_w - 28)
  end

  if ImGui.Button(ctx, "⚙##reapch_settings_btn") then
    ImGui.OpenPopup(ctx, "reapch_settings_popup")
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
      mark_dirty()
    end

    if pal and pal.mode then
      local mode_desc = "Studio Dark (默认独立深色)"
      if pal.mode == "host_light" then
        mode_desc = "宿主浅色主题自适应 (已启用对比度保护)"
      elseif pal.mode == "host_dark" then
        mode_desc = "宿主深色主题自适应 (已启用对比度保护)"
      end
      ImGui.TextDisabled(ctx, "当前视觉模式: " .. mode_desc)
    end

    ImGui.EndPopup(ctx)
  end
end

--- 绘制上半区：0 号位 · Channel Strip（音色塑形区）
local function render_upper_strip_zone(ctx, ImGui, vm, mark_dirty, pal)
  ImGui.Separator(ctx)

  local hdr_bounds = draw_zone_header_card(
    ctx,
    ImGui,
    pal.strip_zone_bg,
    pal.strip_zone_border,
    pal.strip_accent
  )

  if has_imgui(ImGui, "AlignTextToFramePadding") then
    ImGui.AlignTextToFramePadding(ctx)
  end
  local hdr_avail_w = has_imgui(ImGui, "GetContentRegionAvail") and ImGui.GetContentRegionAvail(ctx) or 240
  local hdr_title_w = vm.strip.initialized and math.max(136, hdr_avail_w - 118) or math.max(148, hdr_avail_w - 62)
  local pushed_hdr = push_style_color(ctx, ImGui, "Col_Text", pal.row_slot_strip)
  ImGui.Selectable(ctx, "◆ 0 号位 · Channel Strip##strip_zone_hdr", false, 0, hdr_title_w, 0)
  pop_style_color(ctx, ImGui, pushed_hdr)
  attach_zone_drop_target(ctx, ImGui, vm, "strip", nil, mark_dirty, pal, hdr_bounds)

  if vm.strip.initialized then
    ImGui.SameLine(ctx)
    local chg_master, new_master = ImGui.Checkbox(
      ctx,
      "启用##strip_master_enable",
      vm.strip.enabled and true or false
    )
    if chg_master then
      core.set_strip_enabled(vm.track, new_master)
      mark_dirty()
    end
  end

  ImGui.SameLine(ctx)
  local avail_w = has_imgui(ImGui, "GetContentRegionAvail") and ImGui.GetContentRegionAvail(ctx) or 0
  if avail_w > 54 then
    ImGui.SetCursorPosX(ctx, ImGui.GetCursorPosX(ctx) + avail_w - 54)
  end
  if ImGui.Button(ctx, "+ 添加##strip_add_fx_btn") then
    open_fx_browser_popup(ctx, ImGui, "strip")
  end

  -- MCP 手滑偏离提示条与一键归位
  if vm.strip.initialized and vm.strip.is_displaced then
    ImGui.Spacing(ctx)
    local pushed_warn = push_style_color(ctx, ImGui, "Col_Text", pal.warning_text)
    ImGui.TextWrapped(
      ctx,
      string.format("⚠ Strip 不在信号链最前端（当前位置 #%d）", tonumber(vm.strip.displaced_pos) or 0)
    )
    pop_style_color(ctx, ImGui, pushed_warn)
    if ImGui.Button(ctx, "一键归位##snap_strip_btn") then
      core.snap_strip_to_top(vm.track)
      mark_dirty()
    end
    ImGui.Spacing(ctx)
  end

  if not vm.strip.initialized then
    if ImGui.Button(ctx, "+ 初始化 0 号位 Strip (或直接拖入下方插件)##init_strip_btn") then
      core.init_strip_container(vm.track)
      mark_dirty()
    end
    attach_zone_drop_target(ctx, ImGui, vm, "strip", nil, mark_dirty, pal)
    return
  end

  if #vm.strip.children == 0 then
    local pushed_empty = push_style_color(ctx, ImGui, "Col_Text", pal.text_disabled)
    local clicked_empty = ImGui.Selectable(
      ctx,
      "  (Strip 容器为空，点击 [+ 添加] 或将下方插件拖入此处)##strip_empty_drop",
      false
    )
    pop_style_color(ctx, ImGui, pushed_empty)
    if clicked_empty then
      open_fx_browser_popup(ctx, ImGui, "strip")
    end
    attach_zone_drop_target(ctx, ImGui, vm, "strip", nil, mark_dirty, pal)
    return
  end

  local total_children = #vm.strip.children
  for _, child in ipairs(vm.strip.children) do
    render_fx_row(ctx, ImGui, vm, child, "strip", total_children, mark_dirty, pal)
  end

  local pushed_tail = push_style_color(ctx, ImGui, "Col_Text", pal.text_disabled)
  local clicked_tail = ImGui.Selectable(ctx, "  + 添加 / 拖放至此追加到 Strip 末尾##strip_tail_drop", false)
  pop_style_color(ctx, ImGui, pushed_tail)
  if clicked_tail then
    open_fx_browser_popup(ctx, ImGui, "strip")
  end
  attach_zone_drop_target(ctx, ImGui, vm, "strip", nil, mark_dirty, pal)
end

--- 绘制下半区：常规 FX 槽（视觉从 1 号位起）
local function render_lower_normal_zone(ctx, ImGui, vm, mark_dirty, pal)
  ImGui.Spacing(ctx)
  ImGui.Separator(ctx)

  local hdr_bounds = draw_zone_header_card(
    ctx,
    ImGui,
    pal.normal_zone_bg,
    pal.normal_zone_border,
    pal.normal_accent
  )

  if has_imgui(ImGui, "AlignTextToFramePadding") then
    ImGui.AlignTextToFramePadding(ctx)
  end
  local hdr_avail_w = has_imgui(ImGui, "GetContentRegionAvail") and ImGui.GetContentRegionAvail(ctx) or 240
  local hdr_title_w = math.max(148, hdr_avail_w - 62)
  local pushed_hdr = push_style_color(ctx, ImGui, "Col_Text", pal.row_slot_normal)
  ImGui.Selectable(ctx, "● 常规 FX 槽 (1..N)##normal_zone_hdr", false, 0, hdr_title_w, 0)
  pop_style_color(ctx, ImGui, pushed_hdr)
  attach_zone_drop_target(ctx, ImGui, vm, "normal", nil, mark_dirty, pal, hdr_bounds)

  ImGui.SameLine(ctx)
  local avail_w = has_imgui(ImGui, "GetContentRegionAvail") and ImGui.GetContentRegionAvail(ctx) or 0
  if avail_w > 54 then
    ImGui.SetCursorPosX(ctx, ImGui.GetCursorPosX(ctx) + avail_w - 54)
  end
  if ImGui.Button(ctx, "+ 添加##normal_add_fx_btn") then
    open_fx_browser_popup(ctx, ImGui, "normal")
  end

  if #vm.normal_fx == 0 then
    local pushed_empty = push_style_color(ctx, ImGui, "Col_Text", pal.text_disabled)
    local clicked_empty = ImGui.Selectable(
      ctx,
      "  (无常规插件，点击 [+ 添加] 或将上方 Strip 插件拖入此处)##normal_empty_drop",
      false
    )
    pop_style_color(ctx, ImGui, pushed_empty)
    if clicked_empty then
      open_fx_browser_popup(ctx, ImGui, "normal")
    end
    attach_zone_drop_target(ctx, ImGui, vm, "normal", nil, mark_dirty, pal)
    return
  end

  local total_normal = #vm.normal_fx
  for _, fx in ipairs(vm.normal_fx) do
    render_fx_row(ctx, ImGui, vm, fx, "normal", total_normal, mark_dirty, pal)
  end

  local pushed_tail = push_style_color(ctx, ImGui, "Col_Text", pal.text_disabled)
  local clicked_tail = ImGui.Selectable(ctx, "  + 添加 / 拖放至此追加到常规槽末尾##normal_tail_drop", false)
  pop_style_color(ctx, ImGui, pushed_tail)
  if clicked_tail then
    open_fx_browser_popup(ctx, ImGui, "normal")
  end
  attach_zone_drop_target(ctx, ImGui, vm, "normal", nil, mark_dirty, pal)
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

    render_header(ctx, ImGui, vm, settings, mark_dirty, is_docked, pal)

    if not vm.has_track then
      ImGui.Separator(ctx)
      ImGui.Spacing(ctx)
      ImGui.TextDisabled(ctx, "请在 REAPER 中选中一条轨道以查看双区插件。")
    else
      render_upper_strip_zone(ctx, ImGui, vm, mark_dirty, pal)
      render_lower_normal_zone(ctx, ImGui, vm, mark_dirty, pal)
    end
    render_fx_browser_popup(ctx, ImGui, vm, mark_dirty)

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
