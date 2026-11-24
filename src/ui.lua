-- src/ui.lua
-- Reaper ProChannel (ReaPCh) — 薄渲染层 (v0.2.0 朴素 ImGui 默认布局操作闭环)
-- 职责：消费 core.lua 输出的双区视图模型，绘制可停靠双区面板、双区独立 + 插件分组搜索弹窗（默认过滤 Synth 乐器、支持 REAPER 原生与自定义分组）、
--       区内与跨区双向拖拽排序、右键/快捷移除、单行轻量 Wet/Dry 干湿比调节、偏离提示条与右上角设置菜单。
-- 说明：遵循 AGENTS.md UI 建构门禁，当前保持朴素 ImGui 默认控件；Studio Dark 配色与自定义绘制留待门禁确认后推进。

local core = require("core")
local theme = require("theme")

local DND_PAYLOAD_TYPE = "REAPCH_DND_FX"

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
  _wet_edit_start = {},
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

--- 为当前上一个 ImGui 控件挂载拖拽释放目标
local function attach_zone_drop_target(ctx, ImGui, vm, target_zone, target_slot, mark_dirty)
  if has_imgui(ImGui, "BeginDragDropTarget") and ImGui.BeginDragDropTarget(ctx) then
    local ok_dnd, payload = ImGui.AcceptDragDropPayload(ctx, DND_PAYLOAD_TYPE)
    if ok_dnd and payload then
      apply_fx_drop(vm, target_zone, target_slot, payload, mark_dirty)
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
    ImGui.Text(ctx, "添加插件至: 0 号位 · Channel Strip")
  else
    ImGui.Text(ctx, "添加插件至: 常规 FX 槽 (1..N)")
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

--- 绘制单行 FX 控件（含独立 Bypass、悬浮窗切换、区内与跨区双向拖拽、右键菜单、单行 Wet/Dry 与快捷移除）
local function render_fx_row(ctx, ImGui, vm, item, zone, total_count, mark_dirty)
  local is_strip = (zone == "strip")
  local slot_num = is_strip and item.slot or item.visual_slot
  local row_id = (item.guid and item.guid ~= "") and item.guid or (zone .. "_idx_" .. tostring(slot_num))

  ImGui.PushID(ctx, row_id)

  -- 1. 单行独立 Bypass 复选框
  local chg_en, new_en = ImGui.Checkbox(ctx, "##row_bypass", item.enabled and true or false)
  if chg_en then
    core.set_fx_enabled(vm.track, item.fx_id, new_en)
    mark_dirty()
  end

  -- 2. 插件名称（点击切换悬浮窗、支持区内排序及上下跨区拖拽、右键上下文菜单）
  ImGui.SameLine(ctx)
  local prefix = is_strip and string.format("0.%d", slot_num) or string.format("%d.", slot_num)
  local display_name = (item.name and item.name ~= "") and item.name or "(Unnamed FX)"
  local label = string.format(
    "%s  %s%s",
    prefix,
    display_name,
    item.enabled and "" or " [旁通]"
  )

  local avail_w = has_imgui(ImGui, "GetContentRegionAvail") and ImGui.GetContentRegionAvail(ctx) or 180
  local right_controls_w = 84 -- 预留右侧 52px Wet 滑条 + 22px 移除按钮 + 间距
  local name_w = math.max(56, avail_w - right_controls_w)

  if ImGui.Selectable(ctx, label, item.is_open and true or false, 0, name_w, 0) then
    core.toggle_fx_floating_window(vm.track, item.fx_id)
    mark_dirty()
  end

  -- 2a. 区内与跨区双向拖拽（统一使用 REAPCH_DND_FX 载荷，底层严格保护 0 号位容器本体）
  if has_imgui(ImGui, "BeginDragDropSource") and ImGui.BeginDragDropSource(ctx) then
    local payload_str = string.format("%s:%d", zone, slot_num)
    ImGui.SetDragDropPayload(ctx, DND_PAYLOAD_TYPE, payload_str)
    ImGui.Text(ctx, string.format("移动 %s %s", prefix, display_name))
    ImGui.EndDragDropSource(ctx)
  end

  attach_zone_drop_target(ctx, ImGui, vm, zone, slot_num, mark_dirty)

  -- 2b. 右键快捷菜单（悬浮窗/旁通/干湿比重置/区内上下移动/跨区移入移出/移除）
  if has_imgui(ImGui, "BeginPopupContextItem") and ImGui.BeginPopupContextItem(ctx, "row_ctx_menu") then
    ImGui.Text(ctx, string.format("%s  %s", prefix, display_name))
    ImGui.Separator(ctx)
    if ImGui.MenuItem(ctx, item.is_open and "隐藏插件悬浮窗" or "打开插件悬浮窗") then
      core.toggle_fx_floating_window(vm.track, item.fx_id)
      mark_dirty()
    end
    if ImGui.MenuItem(ctx, item.enabled and "旁通此插件 (Bypass)" or "启用此插件") then
      core.set_fx_enabled(vm.track, item.fx_id, not item.enabled)
      mark_dirty()
    end
    local cur_pct = tonumber(item.wet_percent) or 100
    if ImGui.MenuItem(ctx, "重置干湿比为 100%", nil, false, cur_pct ~= 100) then
      core.set_fx_wet(vm.track, item.fx_id, 1.0, true)
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

  -- 3. 单行轻量级 Wet/Dry 干湿比调节（拖拽中实时生效不刷 Undo，松手时先恢复拖拽前基线再记录单条 Undo）
  ImGui.SameLine(ctx)
  if has_imgui(ImGui, "SetNextItemWidth") then
    ImGui.SetNextItemWidth(ctx, 52)
  end
  local cur_wet_pct = tonumber(item.wet_percent) or 100
  local chg_wet, new_wet_pct = ImGui.SliderInt(ctx, "##row_wet", cur_wet_pct, 0, 100, "%d%%")
  if chg_wet and ui._wet_edit_start[row_id] == nil then
    ui._wet_edit_start[row_id] = (type(item.wet) == "number") and item.wet or (cur_wet_pct / 100.0)
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

--- 绘制顶部轨道信息栏与右上角 ⚙ 设置按钮
local function render_header(ctx, ImGui, vm, settings, mark_dirty, is_docked)
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
    ImGui.TextDisabled(ctx, "提示: 也可拖拽标题栏(或按住Shift)至边缘蓝框停靠")
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

    ImGui.EndPopup(ctx)
  end
end

--- 绘制上半区：0 号位 · Channel Strip（音色塑形区）
local function render_upper_strip_zone(ctx, ImGui, vm, mark_dirty)
  ImGui.Separator(ctx)
  ImGui.Selectable(ctx, "0 号位 · Channel Strip##strip_zone_hdr", false, 0, 148, 0)
  attach_zone_drop_target(ctx, ImGui, vm, "strip", nil, mark_dirty)

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
    ImGui.TextWrapped(
      ctx,
      string.format("⚠ Strip 不在信号链最前端（当前位置 #%d）", tonumber(vm.strip.displaced_pos) or 0)
    )
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
    attach_zone_drop_target(ctx, ImGui, vm, "strip", nil, mark_dirty)
    return
  end

  if #vm.strip.children == 0 then
    if ImGui.Selectable(ctx, "  (Strip 容器为空，点击 [+ 添加] 或将下方插件拖入此处)##strip_empty_drop", false) then
      open_fx_browser_popup(ctx, ImGui, "strip")
    end
    attach_zone_drop_target(ctx, ImGui, vm, "strip", nil, mark_dirty)
    return
  end

  local total_children = #vm.strip.children
  for _, child in ipairs(vm.strip.children) do
    render_fx_row(ctx, ImGui, vm, child, "strip", total_children, mark_dirty)
  end
  if ImGui.Selectable(ctx, "  + 添加 / 拖放至此追加到 Strip 末尾##strip_tail_drop", false) then
    open_fx_browser_popup(ctx, ImGui, "strip")
  end
  attach_zone_drop_target(ctx, ImGui, vm, "strip", nil, mark_dirty)
end

--- 绘制下半区：常规 FX 槽（视觉从 1 号位起）
local function render_lower_normal_zone(ctx, ImGui, vm, mark_dirty)
  ImGui.Spacing(ctx)
  ImGui.Separator(ctx)
  ImGui.Selectable(ctx, "常规 FX 槽 (1..N)##normal_zone_hdr", false, 0, 148, 0)
  attach_zone_drop_target(ctx, ImGui, vm, "normal", nil, mark_dirty)

  ImGui.SameLine(ctx)
  local avail_w = has_imgui(ImGui, "GetContentRegionAvail") and ImGui.GetContentRegionAvail(ctx) or 0
  if avail_w > 54 then
    ImGui.SetCursorPosX(ctx, ImGui.GetCursorPosX(ctx) + avail_w - 54)
  end
  if ImGui.Button(ctx, "+ 添加##normal_add_fx_btn") then
    open_fx_browser_popup(ctx, ImGui, "normal")
  end

  if #vm.normal_fx == 0 then
    if ImGui.Selectable(ctx, "  (无常规插件，点击 [+ 添加] 或将上方 Strip 插件拖入此处)##normal_empty_drop", false) then
      open_fx_browser_popup(ctx, ImGui, "normal")
    end
    attach_zone_drop_target(ctx, ImGui, vm, "normal", nil, mark_dirty)
    return
  end

  local total_normal = #vm.normal_fx
  for _, fx in ipairs(vm.normal_fx) do
    render_fx_row(ctx, ImGui, vm, fx, "normal", total_normal, mark_dirty)
  end
  if ImGui.Selectable(ctx, "  + 添加 / 拖放至此追加到常规槽末尾##normal_tail_drop", false) then
    open_fx_browser_popup(ctx, ImGui, "normal")
  end
  attach_zone_drop_target(ctx, ImGui, vm, "normal", nil, mark_dirty)
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

    render_header(ctx, ImGui, vm, settings, mark_dirty, is_docked)

    if not vm.has_track then
      ImGui.Separator(ctx)
      ImGui.Spacing(ctx)
      ImGui.TextDisabled(ctx, "请在 REAPER 中选中一条轨道以查看双区插件。")
    else
      render_upper_strip_zone(ctx, ImGui, vm, mark_dirty)
      render_lower_normal_zone(ctx, ImGui, vm, mark_dirty)
    end
    render_fx_browser_popup(ctx, ImGui, vm, mark_dirty)

    -- 注意：ReaImGui 0.9 / 0.10 规范要求仅在 ImGui.Begin 返回 visible == true 时调用 ImGui.End
    ImGui.End(ctx)
  end

  theme.pop(ctx, ImGui, col_cnt, var_cnt)
  return open
end

return ui
