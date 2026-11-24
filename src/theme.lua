-- src/theme.lua
-- Reaper ProChannel (ReaPCh) — 配色与布局常量骨架 (v0.1.0)
-- 说明：按 AGENTS.md UI 建构门禁要求，v0.1.0 保持最朴素的 ImGui 默认布局；
-- Studio Dark 视觉体系定型与可选宿主配色适配将在 v0.2.0 触发 UI 建构门禁后推进。

local theme = {}

theme.DEFAULT_WINDOW_WIDTH = 280
theme.DEFAULT_WINDOW_HEIGHT = 620

--- v0.1.0 暂不覆盖 ImGui 默认配色栈，返回压栈数量 0, 0
function theme.push(_ctx, _ImGui, _settings)
  return 0, 0
end

--- v0.1.0 弹出配色与样式栈（数量为 0 时无操作）
function theme.pop(ctx, ImGui, color_count, var_count)
  if color_count and color_count > 0 then
    ImGui.PopStyleColor(ctx, color_count)
  end
  if var_count and var_count > 0 then
    ImGui.PopStyleVar(ctx, var_count)
  end
end

return theme
