# DEVLOG.md

- **当前版本**：`v0.2.0`（完整操作闭环 + 朴素 ImGui 默认布局；视觉体系定型待触发 UI 建构门禁）
- **项目简称**：`ReaPCh`（Reaper ProChannel）
- **前置环境**：
  - `docs/imgui.lua`：已确认，本机 ReaImGui 动态垫片（`reaper_imgui-x64` `v0.10.0.5`），支持 `require 'imgui' '0.10'`（向下兼容 `'0.9'`）；垫片在加载时已对 `flags & 1 ~= 0` 的枚举常量预求值，且遵循 ReaImGui 0.9/0.10 规范仅在 `ImGui.Begin` / `ImGui.BeginChild` 返回 `visible == true` 时调用 `ImGui.End` / `ImGui.EndChild`。
  - `tests/run.lua`：`v0.1.0` 7 组边界测试已在 REAPER 7 宿主内置 Lua 5.4 环境中实机验证全部 PASS；`v0.2.0` 扩展至 **10 组**边界单元测试用例（新增 `EnumInstalledFX` 枚举缓存与搜索、单行 Wet/Dry 原生参数读写、双区双向排序与跨偏离容器排序闭环）。

## 已完成（`v0.2.0` 核心逻辑与朴素操作闭环）
- **`src/core.lua`（纯逻辑层扩展，零 ImGui 依赖）**：
  - **已安装插件枚举缓存与多关键词搜索（`EnumInstalledFX`）**：实现 `core.get_installed_fx(force_refresh)`、`core.clear_installed_fx_cache()` 与 `core.filter_installed_fx(query, max_results, force_refresh)`；自动过滤空项与裸 `Container` 容器本体，解析插件格式前缀（`VST3` / `VST` / `CLAP` / `JS` 等），支持空格分词多关键词联合检索与纯文本子串匹配（`string.find(..., 1, true)`，彻底免疫插件名或搜索词中 `- + ( ) [ ] % .` 等正则特殊字符引发的模式报错）。
  - **单行 Wet/Dry 原生干湿比参数读写**：实现 `core.get_fx_wet_param_index(tr, fx_id)`（优先调用 `TrackFX_GetParamFromIdent(tr, fx_id, ":wet")`，自动向下兼容回退 `TrackFX_GetNumParams` + `TrackFX_GetParamName("Wet")`）、`core.get_fx_wet(tr, fx_id)` 与 `core.set_fx_wet(tr, fx_id, wet_0_to_1, record_undo, pre_undo_wet_0_to_1)`；支持顶层常规插件与 `0x2000000+` 容器子插件的干湿比读写、`[0.0, 1.0]` 边界夹紧、NaN/越界拦截及拖拽过程中的按需 Undo 控制（`record_undo = false` 实时调参不刷 Undo，松手时先恢复拖拽前基线值 `pre_undo_wet_0_to_1` 再在 `Undo_BeginBlock`..`Undo_EndBlock` 内写入终值，确保 `Ctrl+Z` 一步退回拖拽前干湿比）；视图模型每项自动输出 `wet` (`0.0..1.0`) 与 `wet_percent` (`0..100`)。
- **`tests/mock_reaper.lua` & `tests/run.lua`（单元测试套件扩展至 10 组）**：
  - 在 `mock_reaper.lua` 中新增 `EnumInstalledFX`、`mock_set_installed_fx`、`TrackFX_GetParamFromIdent(":wet")`、`TrackFX_GetNumParams`、`TrackFX_GetParamName`、`TrackFX_GetParam`、`TrackFX_SetParam` 及节点 `wet` 状态跨容器复制/移动保持。
  - 在完整保留 `v0.1.0` 全部 7 组单元测试的基础上，新增用例 8（`EnumInstalledFX` 缓存、强制刷新、多关键词与特殊字符过滤、搜索添加闭环）、用例 9（单行 Wet/Dry 读写、边界夹紧、回退机制与 Undo 控制）、用例 10（双区双向排序 `from < to` & `from > to`、跨偏离容器排序与干湿比状态保持）。
- **`src/ui.lua`（朴素 ImGui 默认控件接通 `v0.2.0` 完整操作闭环）**：
  - **双区独立 `+ 添加` 插件搜索弹窗**：上半区与下半区标题栏各自提供 `+ 添加` 按钮，点击弹出带自动聚焦搜索框的已安装插件列表（支持关键词即时过滤、清空搜索、手动刷新插件缓存；未初始化 Strip 时点击上半区 `+ 添加` 并选中插件可自动创建 0 号位容器并置入）。
  - **双区各自内部拖拽排序与右键/快捷移除**：基于独立 Drag & Drop Payload 类型（`REAPCH_DND_STRIP` vs `REAPCH_DND_NORMAL`）实现双区严格物理隔离的区内拖拽排序；每行同时提供右键上下文菜单（打开/隐藏悬浮窗、启用/旁通、重置干湿比为 100%、上移 ▲ / 下移 ▼、移除插件）及行尾 `×` 快捷移除按钮。
  - **单行轻量级 Wet/Dry 调节**：每行右侧提供 `0%..100%` 干湿比滑条，拖拽过程中实时更新宿主音频参数，松手时（`IsItemDeactivatedAfterEdit`）合并记录单次 Undo。

## 已完成（`v0.1.0` 基础回顾）
- 0 号位容器 `P_EXT:REAPCH_STRIP_GUID` 持久化认亲、按需初始化（`◆ CHANNEL STRIP ◆`）、手动删容器优雅降级、MCP 手滑偏离检测与一键/自动归位。
- REAPER 7.06+ `0x2000000+` 容器编址正反解、下半区隐藏容器与 `1..N` 视觉重编号映射、全套边界硬拦截。
- ReaImGui `0.10`/`0.9` 可停靠上下文、`GetProjectStateChangeCount` 零空转扫描防抖循环及右上角 `⚙ -> [一键停靠至 REAPER Docker]`。

## 待触发 UI 建构门禁项（`v0.2.0` 视觉体系定型）
按 `AGENTS.md` **UI 建构门禁（额度保护）** 规定，以下涉及重大 UI 建构的工作在核心操作闭环跑通后暂停，待用户确认执行方式（切换指定模型执行 / 当前模型直接实现 / 暂且搁置）：
1. **`src/theme.lua` Studio Dark 视觉体系定型与宿主配色适配**（预估复杂度：**中**）：
   - 低饱和中性深色配色栈（区分 0 号位音色塑形区与下半区常规槽的卡片底色、边框与激活态高亮）。
   - 实验性 `跟随 REAPER 宿主主题配色` 开关实现（基于 `reaper.GetThemeColor()` 读取宿主背景/文字色，附带明度对比度安全兜底以防第三方位图皮肤文字不可读）。
2. **双区卡片排版与拖拽视觉反馈精修**（预估复杂度：**中**）：
   - 紧凑单行间距、Bypass 状态指示灯、拖拽目标插入高亮线及 Wet/Dry 微型控件视觉打磨。

## 远期规划备忘：单轨 Inspector 混音扩展笔记（`v0.4.0+`，排在双区 FX 核心路线之后）
用户已确认的远期演进方向（在双区 FX 与 `v0.3.0` Strip 预设体系稳定后按以下优先级推进）：
1. **单轨混音核心组件（高优先级远期项）**：
   - **顶部录音与高频通道开关**：录音预备（`R`）、监听（`Mon`）、静音（`M`）、独奏（`S`）、反相（`Ø`）。
   - **发送槽列表（`Sends`）**：轨道发送列表展示、发送量快捷调节与静音开关。
   - **底部声像/宽度与推子区**：`Pan / Width`（UI 阶段倾向采用**经典圆弧旋钮**而非水平拉条）+ 音量推子（Fader）+ 可选实时 L/R 电平表。
2. **底部 `In / MIDI / Out` 路由摘要（中低优先级远期项）**：
   - 仅做**轻量两行文字状态摘要展示**（如当前输入源与 Master Send 状态）+ **点击呼出 REAPER 原生路由窗口**，不在窄侧边栏内重造复杂路由矩阵。
3. **顶部 Pre-FX Gain 旋钮（低优先级 Opt-in 可选项）**：
   - 不强制默认内置；作为低优先级可选方案（Opt-in），仅在用户显式开启时按需调用 REAPER 原厂自带的 `JS: Volume Adjustment` 联动 dB 参数。

## 下一步
1. 在 REAPER 7 内运行 `tests/run.lua` 验收全部 10 组单元测试，并在 `src/main.lua` 中实机体验双区 `+ 添加` 搜索弹窗、区内拖拽/右键排序、单行 Wet/Dry 滑条与 `×` 快捷移除。
2. 触发 UI 建构门禁：由用户决定是否立即推进 `src/theme.lua` Studio Dark 配色与双区视觉精修，或先搁置视觉直接推进 `v0.3.0` Strip 预设管理。
