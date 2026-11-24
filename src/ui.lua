-- src/ui.lua
-- Reaper ProChannel (ReaPCh) — 薄渲染层 (v0.2.0 朴素 ImGui 默认布局操作闭环)
-- 职责：消费 core.lua 输出的双区视图模型，绘制可停靠双区面板、双区独立 + 插件搜索弹窗、
--       区内拖拽排序与右键/快捷移除、单行轻量 Wet/Dry 干湿比调节、偏离提示条与右上角设置菜单。
-- 说明：遵循 AGENTS.md UI 建构门禁，当前保持朴素 ImGui 默认控件；Studio Dark 配色与自定义绘制留待门禁确认后推进。

local core = require("core")
local theme = require("theme")

local ui = {
  _pending_dock_id = nil,
  _last_dock_id = -1,
  _browser_target_zone = "strip", -- "strip" | "normal"
  _fx_search_query = "",
  _focus_search_input = false,
  _wet_edit_start = {},
}

local function enum_val(v)
  if type(v) == "function" then
    return v()
  end
  return v or 0
end

local function open_fx_browser_popup(ctx, ImGui, zone)
  ui._browser_target_zone = (zone == "normal") and "normal" or "strip"
  ui._focus_search_input = true
  ImGui.OpenPopup(ctx, "reapch_fx_browser_popup")
end

--- 绘制双区共用的已安装插件搜索与添加弹窗（按 _browser_target_zone 分流至 0 号位容器或常规槽）
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

  if ui._focus_search_input and ImGui.SetKeyboardFocusHere then
    ImGui.SetKeyboardFocusHere(ctx)
    ui._focus_search_input = false
  end

  if ImGui.SetNextItemWidth then
    ImGui.SetNextItemWidth(ctx, 210)
  end
  local chg_q, new_q
  if ImGui.InputTextWithHint then
    chg_q, new_q = ImGui.InputTextWithHint(
      ctx,
      "##reapch_fx_search",
      "搜索插件 (如 eq / vst3 / comp)...",
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
  end

  ImGui.SameLine(ctx)
  if ImGui.Button(ctx, "清空##reapch_clear_search") then
    ui._fx_search_query = ""
  end

  ImGui.SameLine(ctx)
  if ImGui.Button(ctx, "刷新##reapch_refresh_fx_cache") then
    core.get_installed_fx(true)
  end

  local results, total_matched = core.filter_installed_fx(ui._fx_search_query, 200)
  if total_matched > #results then
    ImGui.TextDisabled(
      ctx,
      string.format("匹配 %d 个插件 (仅显示前 %d 个，请继续输入关键词)", total_matched, #results)
    )
  else
    ImGui.TextDisabled(ctx, string.format("匹配 %d 个插件", total_matched))
  end

  local should_close_popup = false
  local list_visible = ImGui.BeginChild(ctx, "reapch_fx_browser_list", 330, 240)
  if list_visible then
    if #results == 0 then
      ImGui.TextDisabled(ctx, "  (未找到匹配的已安装插件)")
    else
      for idx, item in ipairs(results) do
        ImGui.PushID(ctx, tostring(item.index or idx))
        if ImGui.Selectable(ctx, item.name, false) then
          if ui._browser_target_zone == "strip" then
            core.add_fx_to_strip(vm.track, item.add_name)
          else
            core.add_normal_fx(vm.track, item.add_name)
          end
          mark_dirty()
          should_close_popup = true
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

--- 绘制单行 FX 控件（含独立 Bypass、悬浮窗切换、区内拖拽排序、右键菜单、单行 Wet/Dry 与快捷移除）
local function render_fx_row(ctx, ImGui, vm, item, zone, total_count, mark_dirty)
  local is_strip = (zone == "strip")
  local slot_num = is_strip and item.slot or item.visual_slot
  local dnd_type = is_strip and "REAPCH_DND_STRIP" or "REAPCH_DND_NORMAL"
  local row_id = (item.guid and item.guid ~= "") and item.guid or (zone .. "_idx_" .. tostring(slot_num))

  ImGui.PushID(ctx, row_id)

  -- 1. 单行独立 Bypass 复选框
  local chg_en, new_en = ImGui.Checkbox(ctx, "##row_bypass", item.enabled and true or false)
  if chg_en then
    core.set_fx_enabled(vm.track, item.fx_id, new_en)
    mark_dirty()
  end

  -- 2. 插件名称（点击切换悬浮窗、拖拽区内排序、右键上下文菜单）
  ImGui.SameLine(ctx)
  local prefix = is_strip and string.format("0.%d", slot_num) or string.format("%d.", slot_num)
  local display_name = (item.name and item.name ~= "") and item.name or "(Unnamed FX)"
  local label = string.format(
    "%s  %s%s",
    prefix,
    display_name,
    item.enabled and "" or " [旁通]"
  )

  local avail_w = ImGui.GetContentRegionAvail and ImGui.GetContentRegionAvail(ctx) or 180
  local right_controls_w = 84 -- 预留右侧 52px Wet 滑条 + 22px 移除按钮 + 间距
  local name_w = math.max(56, avail_w - right_controls_w)

  if ImGui.Selectable(ctx, label, item.is_open and true or false, 0, name_w, 0) then
    core.toggle_fx_floating_window(vm.track, item.fx_id)
    mark_dirty()
  end

  -- 2a. 区内拖拽排序（通过独立 payload 类型严格隔离上下双区，禁止跨区覆写）
  if ImGui.BeginDragDropSource and ImGui.BeginDragDropSource(ctx) then
    ImGui.SetDragDropPayload(ctx, dnd_type, tostring(slot_num))
    ImGui.Text(ctx, string.format("移动 %s %s", prefix, display_name))
    ImGui.EndDragDropSource(ctx)
  end

  if ImGui.BeginDragDropTarget and ImGui.BeginDragDropTarget(ctx) then
    local ok_dnd, payload = ImGui.AcceptDragDropPayload(ctx, dnd_type)
    if ok_dnd and payload then
      local from_slot = tonumber(payload)
      if from_slot and from_slot ~= slot_num then
        if is_strip then
          core.move_strip_fx(vm.track, from_slot, slot_num)
        else
          core.move_normal_fx(vm.track, from_slot, slot_num)
        end
        mark_dirty()
      end
    end
    ImGui.EndDragDropTarget(ctx)
  end

  -- 2b. 右键快捷菜单（悬浮窗/旁通/干湿比重置/上下移动/移除）
  if ImGui.BeginPopupContextItem and ImGui.BeginPopupContextItem(ctx, "row_ctx_menu") then
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
  if ImGui.SetNextItemWidth then
    ImGui.SetNextItemWidth(ctx, 52)
  end
  local cur_wet_pct = tonumber(item.wet_percent) or 100
  local chg_wet, new_wet_pct = ImGui.SliderInt(ctx, "##row_wet", cur_wet_pct, 0, 100, "%d%%")
  if chg_wet and ui._wet_edit_start[row_id] == nil then
    ui._wet_edit_start[row_id] = (type(item.wet) == "number") and item.wet or (cur_wet_pct / 100.0)
  end
  local deactivated = ImGui.IsItemDeactivatedAfterEdit and ImGui.IsItemDeactivatedAfterEdit(ctx)
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
  ImGui.Text(ctx, "0 号位 · Channel Strip")

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
  local avail_w = ImGui.GetContentRegionAvail and ImGui.GetContentRegionAvail(ctx) or 0
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
    if ImGui.Button(ctx, "+ 初始化 0 号位 Strip##init_strip_btn") then
      core.init_strip_container(vm.track)
      mark_dirty()
    end
    return
  end

  if #vm.strip.children == 0 then
    ImGui.TextDisabled(ctx, "  (Strip 容器为空，点击右上 [+ 添加] 置入插件)")
    return
  end

  local total_children = #vm.strip.children
  for _, child in ipairs(vm.strip.children) do
    render_fx_row(ctx, ImGui, vm, child, "strip", total_children, mark_dirty)
  end
end

--- 绘制下半区：常规 FX 槽（视觉从 1 号位起）
local function render_lower_normal_zone(ctx, ImGui, vm, mark_dirty)
  ImGui.Spacing(ctx)
  ImGui.Separator(ctx)
  ImGui.Text(ctx, "常规 FX 槽 (1..N)")

  ImGui.SameLine(ctx)
  local avail_w = ImGui.GetContentRegionAvail and ImGui.GetContentRegionAvail(ctx) or 0
  if avail_w > 54 then
    ImGui.SetCursorPosX(ctx, ImGui.GetCursorPosX(ctx) + avail_w - 54)
  end
  if ImGui.Button(ctx, "+ 添加##normal_add_fx_btn") then
    open_fx_browser_popup(ctx, ImGui, "normal")
  end

  if #vm.normal_fx == 0 then
    ImGui.TextDisabled(ctx, "  (无常规插件，点击右上 [+ 添加] 置入插件)")
    return
  end

  local total_normal = #vm.normal_fx
  for _, fx in ipairs(vm.normal_fx) do
    render_fx_row(ctx, ImGui, vm, fx, "normal", total_normal, mark_dirty)
  end
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

  local cond_first_use = enum_val(ImGui.Cond_FirstUseEver)
  ImGui.SetNextWindowSize(
    ctx,
    theme.DEFAULT_WINDOW_WIDTH,
    theme.DEFAULT_WINDOW_HEIGHT,
    cond_first_use
  )

  if ui._pending_dock_id ~= nil and ImGui.SetNextWindowDockID then
    ImGui.SetNextWindowDockID(ctx, ui._pending_dock_id)
    ui._pending_dock_id = nil
  end

  local col_cnt, var_cnt = theme.push(ctx, ImGui, settings)
  local window_flags = enum_val(ImGui.WindowFlags_None)
  local visible, open = ImGui.Begin(ctx, "Reaper ProChannel", true, window_flags)

  if visible then
    local is_docked = false
    if ImGui.IsWindowDocked then
      is_docked = ImGui.IsWindowDocked(ctx) and true or false
    end
    if is_docked and ImGui.GetWindowDockID then
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
