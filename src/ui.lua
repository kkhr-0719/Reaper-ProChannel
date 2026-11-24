-- src/ui.lua
-- Reaper ProChannel (ReaPCh) — 薄渲染层 (v0.1.0 朴素 ImGui 默认布局)
-- 职责：消费 core.lua 输出的双区视图模型，绘制可停靠双区面板、偏离提示条与右上角设置菜单。

local core = require("core")
local theme = require("theme")

local ui = {
  _pending_dock_id = nil,
  _last_dock_id = -1,
}

local function enum_val(v)
  if type(v) == "function" then
    return v()
  end
  return v or 0
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
    ImGui.TextDisabled(ctx, "  (Strip 容器为空)")
    return
  end

  for i, child in ipairs(vm.strip.children) do
    local row_id = (child.guid and child.guid ~= "") and child.guid or ("strip_idx_" .. tostring(i))
    ImGui.PushID(ctx, row_id)

    local chg_en, new_en = ImGui.Checkbox(ctx, "##child_bypass", child.enabled and true or false)
    if chg_en then
      core.set_fx_enabled(vm.track, child.fx_id, new_en)
      mark_dirty()
    end

    ImGui.SameLine(ctx)
    local label = string.format(
      "0.%d  %s%s",
      child.slot,
      child.name ~= "" and child.name or "(Unnamed FX)",
      child.enabled and "" or " [旁通]"
    )
    if ImGui.Selectable(ctx, label, child.is_open and true or false) then
      core.toggle_fx_floating_window(vm.track, child.fx_id)
      mark_dirty()
    end

    ImGui.PopID(ctx)
  end
end

--- 绘制下半区：常规 FX 槽（视觉从 1 号位起）
local function render_lower_normal_zone(ctx, ImGui, vm, mark_dirty)
  ImGui.Spacing(ctx)
  ImGui.Separator(ctx)
  ImGui.Text(ctx, "常规 FX 槽 (1..N)")

  if #vm.normal_fx == 0 then
    ImGui.TextDisabled(ctx, "  (无常规插件)")
    return
  end

  for i, fx in ipairs(vm.normal_fx) do
    local row_id = (fx.guid and fx.guid ~= "") and fx.guid or ("normal_idx_" .. tostring(i))
    ImGui.PushID(ctx, row_id)

    local chg_en, new_en = ImGui.Checkbox(ctx, "##normal_bypass", fx.enabled and true or false)
    if chg_en then
      core.set_fx_enabled(vm.track, fx.fx_id, new_en)
      mark_dirty()
    end

    ImGui.SameLine(ctx)
    local label = string.format(
      "%d.  %s%s",
      fx.visual_slot,
      fx.name ~= "" and fx.name or "(Unnamed FX)",
      fx.enabled and "" or " [旁通]"
    )
    if ImGui.Selectable(ctx, label, fx.is_open and true or false) then
      core.toggle_fx_floating_window(vm.track, fx.fx_id)
      mark_dirty()
    end

    ImGui.PopID(ctx)
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

    -- 注意：ReaImGui 0.9 / 0.10 规范要求仅在 ImGui.Begin 返回 visible == true 时调用 ImGui.End
    ImGui.End(ctx)
  end

  theme.pop(ctx, ImGui, col_cnt, var_cnt)
  return open
end

return ui
