# DEVLOG.md

- **当前版本**：`v0.1.0`（核心骨架 + 朴素双区 MVP）
- **项目简称**：`ReaPCh`（Reaper ProChannel）
- **前置环境**：
  - `docs/imgui.lua`：已确认，本机 ReaImGui 动态垫片（`reaper_imgui-x64` `v0.10.0.5`），支持 `require 'imgui' '0.10'`（向下兼容 `'0.9'`）；垫片在加载时已对 `flags & 1 ~= 0` 的枚举常量预求值，且遵循 ReaImGui 0.9/0.10 规范仅在 `ImGui.Begin` 返回 `visible == true` 时调用 `ImGui.End`。
  - `tests/run.lua`：已在 REAPER 7 宿主内置 Lua 5.4 环境中实机运行，7 组边界单元测试全部通过（`Total: 7 | Passed: 7 | Failed: 0`）。

## 已完成（`v0.1.0`）
- **`src/core.lua`（纯逻辑层，零 ImGui 依赖）**：
  - 实现 0 号位容器 `P_EXT:REAPCH_STRIP_GUID`（向下兼容读取 `P_EXT:RPROCH_STRIP_GUID`）持久化认亲、按需初始化（顶层 `index 0` 创建 `Container` 并重命名为 `◆ CHANNEL STRIP ◆`）与手动删空容器优雅降级。
  - 实现 REAPER 7.06+ 容器编址公式 `0x2000000 + (child_pos_0based + 1) * (parent_fx_count + 1) + (container_idx_0based + 1)` 的正反解、子插件平铺读取、向容器末尾添加插件（未初始化时自动先建容器再置入，若插件实例化失败则自动原子回滚已建容器与 `P_EXT`）、容器内排序与删除。
  - 实现 MCP 手滑偏离检测（`container_index > 0`）、一键归位（`snap_strip_to_top`）与 `Auto-Snap Strip to Slot 0` 自动归位逻辑。
  - 实现下半区常规 FX 过滤（隐藏 0 号位容器本体）、`1..N` 视觉重编号映射（`visual_slot_to_top_index`）以及常规 FX 插入（`add_normal_fx`）、排序（`move_normal_fx`）、删除（`delete_normal_fx` / `delete_top_fx_guarded`）全套边界硬拦截（无论容器在 `0` 号位还是偏离至非 `0` 号位均严禁误伤或挤占容器）。
  - 实现整区总 Bypass、单行 Bypass、原生 VST 悬浮窗显隐切换（含越界 `fx_id` 防御校验）及 `ExtState("REAPCH", ...)`（向下兼容读取 `"RPROCH"`）配置持久化。
- **`tests/mock_reaper.lua` & `tests/run.lua`（单元测试套件）**：
  - 实现完整模拟 REAPER 7.06+ 轨道、顶层 FX、`0x2000000+` 容器编址、`TrackFX_CopyToTrack`、`P_EXT` 与 `ExtState` 的纯 Lua 测试桩。
  - 编写并实机跑通覆盖 `docs/SPEC.md` 5.5 节全部 6 类必测边界场景及容器内排序/移除/Bypass/悬浮窗/ExtState 的 7 组单元测试用例；修复 `run_test` 输出中 `[PASS] 1. 1.` 序号重复问题。
- **`src/main.lua`、`src/ui.lua`、`src/theme.lua` & `README.md`（朴素双区 MVP）**：
  - 实现 ReaImGui 环境兜底检测、`0.10`/`0.9` 垫片加载、启用 `ConfigFlags_DockingEnable` 的可停靠上下文及基于 `GetProjectStateChangeCount(0)` + `GetSelectedTrack(0, 0)` 的零空转扫描防抖主循环（已在 REAPER 7 实机启动验证）。
  - 实现朴素 ImGui 默认布局的上下双区面板、偏离警告条与 `[一键归位]` 按钮。
  - 在右上角 `⚙` 设置菜单中新增 **`[一键停靠至 REAPER Docker]` / `[脱离停靠 (恢复浮动窗口)]`** 快捷按钮（基于 `ImGui.SetNextWindowDockID` 与 `ImGui.IsWindowDocked`），并在 `README.md` 补充 ReaImGui 窗口停靠至 REAPER 左侧 Docker 的完整操作指南。
- **Git 仓库与分支规范**：
  - 初始化 Git 仓库，校验命中目录级 `includeIf` 独立身份配置（含 `credential.useHttpPath true`），在 `feat/v0.1.0-mvp` 分支完成提交。

## 已知问题 / UI Backlog（待后续精修）
- **`v0.2.0` 待建构项（涉及视觉体系定型前需触发 UI 建构门禁）**：
  - 双区独立 `+` 添加插件搜索弹窗（基于 `reaper.EnumInstalledFX` 缓存与关键词过滤）。
  - 双区各自内部拖拽排序（ImGui Drag & Drop 绑定 `core.move_strip_fx` / `core.move_normal_fx`）与右键/快捷移除。
  - 单行轻量级 Wet/Dry 干湿比调节。
  - 触发 UI 建构门禁后，完成 `src/theme.lua` 的 Studio Dark 配色定型与 `reaper.GetThemeColor()` 宿主主题配色适配。

## 下一步
1. 在 REAPER 7 中验证 `⚙ -> [一键停靠至 REAPER Docker]` 及双区日常轨道切换/初始化/Bypass/弹窗交互。
2. 规划 `v0.2.0` 插件搜索弹窗、双区拖拽排序交互及 UI 建构门禁评估。
