# DEVLOG.md

- **当前版本**：`v0.2.0`（完整操作闭环 + 朴素 ImGui 默认布局；视觉体系定型待触发 UI 建构门禁）
- **项目简称**：`ReaPCh`（Reaper ProChannel）
- **前置环境**：
  - `docs/imgui.lua`：已确认，本机 ReaImGui 动态垫片（`reaper_imgui-x64` `v0.10.0.5`），支持 `require 'imgui' '0.10'`（向下兼容 `'0.9'`）；垫片在加载时已对 `flags & 1 ~= 0` 的枚举常量预求值，且遵循 ReaImGui 0.9/0.10 规范仅在 `ImGui.Begin` / `ImGui.BeginChild` 返回 `visible == true` 时调用 `ImGui.End` / `ImGui.EndChild`。
  - `tests/run.lua`：`v0.1.0` 7 组边界测试已在 REAPER 7 宿主内置 Lua 5.4 环境中实机验证全部 PASS；`v0.2.0` 现已扩展至 **13 组**边界单元测试用例（新增 `EnumInstalledFX` 枚举缓存与搜索、单行 Wet/Dry 原生参数读写、双区双向排序、**Synth 乐器插件识别与默认过滤**、**`reaper-fxfolders.ini` / `reaper-fxtags.ini` 解析与多维分组 + 脚本内自定义分组持久化**、**上下双区跨区互相拖拽移入/移出与 0 号位容器保护**）。

## 已完成（`v0.2.0` 核心逻辑与朴素操作闭环 + 实机反馈增强）
- **`src/core.lua`（纯逻辑层扩展，零 ImGui 依赖）**：
  - **已安装插件枚举缓存、运行内 DX 新插件刷新兜底与多关键词搜索（`EnumInstalledFX`）**：实现 `core.get_installed_fx(force_refresh)`、`core.clear_installed_fx_cache()`、`core.parse_dxplugins_ini(content)` 与 `core.filter_installed_fx(query, max_results, force_refresh, opts)`；当 `force_refresh == true` 时先调用 `reaper.EnumInstalledFX(-1)` 尝试刷新宿主插件列表元数据，并补充解析 REAPER 资源目录下的 `reaper-dxplugins64.ini`（回退兼容 `reaper-dxplugins.ini`），将其中 `Load ~= 0`（启用状态）且尚未被 `EnumInstalledFX` 返回的 DX / DXi 插件自动去重合并入列表，解决“运行中途新开启扫描 DX 插件后不重启 REAPER 就刷不出来”的问题；自动过滤空项与裸 `Container` 容器本体，解析插件格式前缀（`VST3` / `VST` / `CLAP` / `JS` / `DX` 等）、短名称与厂商名（自动剥离末尾 `(8ch)` / `(64 out)` / `(mono)` 等通道后缀），支持空格分词多关键词联合检索与纯文本子串匹配（`string.find(..., 1, true)`，彻底免疫正则特殊字符报错）。
  - **Synth 虚拟乐器识别、默认过滤与 4 个 `DXi:` 音频效果器硬编码豁免**：实现 `core.is_instrument_format(fmt)`、`core.is_dxi_effect_exception(name_or_item)` 与 `core.is_instrument_fx(name_or_item, category_tag)`，精准识别 `VSTi` / `VST3i` / `CLAPi` / `AUi` / `LV2i` / `DXi` 格式前缀及 `reaper-fxtags.ini` 中的 `Instrument` / `Synth` 标签；针对 REAPER 因支持 Tempo Sync / MIDI 端口而误标为 `DXi:` 的 4 个已知音频效果器（`Sonitus:fx Delay`、`Cakewalk Tempo Delay`、`Cakewalk Classic Phaser`、`Cakewalk Modfilter`）列入硬编码豁免名单，确保默认隐藏乐器（`include_instruments = false`）时这 4 个效果器仍正常显示；同时支持通过 `opts.include_instruments = true` 按需包含全部乐器。
  - **多维分组体系（严格 A–Z 纯字母序分类 + 统一原生分类名）与 Cakewalk 风格自定义分组**：
    - 支持解析 REAPER 资源目录（`reaper.GetResourcePath()`）下的 `reaper-fxfolders.ini`（含标准 `[Folders]`+`[Folder<id>]` 用户文件夹与 `Type=16777216` 智能文件夹完整布尔过滤语法 `AND` / `OR` / `NOT` / 引号短语 / 括号）与 `reaper-fxtags.ini`（`[category]` 与 `[developer]` 标签，兼容空格/连字符下划线归一化与 `<UID>` 后缀匹配）；对齐 `core.infer_fx_category` 的兜底分类名与 REAPER `reaper-fxtags.ini` 原生分类名（统一使用 `EQ`、`Filter`、`Dynamics`、`Reverb`、`Delay`、`Distortion`、`Modulation`、`Channel Strip`、`Utility`、`Analyzer`、`Other FX`，自动剥离 `FabFilter` 厂商名防止非 EQ/Filter 插件误判），彻底消除同时出现 `EQ` + `EQ & Filter`、`Reverb` + `Reverb & Delay` 的重复分裂现象。
    - 实现脚本内用户自定义分组（`core.get_custom_fx_groups`、`core.add_custom_fx_group`、`core.remove_custom_fx_group`、`core.assign_fx_to_custom_group`、`core.remove_fx_from_custom_group`、`core.is_fx_in_custom_group`），通过 `ExtState`（`REAPCH` -> `custom_fx_groups`）持久化保存；精确按标识符/名称匹配自定义分组与文件夹成员，防止短名插件污染同分类其他插件。
    - 实现 `core.get_grouped_installed_fx(query, group_mode, opts)`，支持 `"category"`（默认：展示 `★ 自定义分组` 与 `📁 REAPER 文件夹` 前缀组后，所有功能分类**彻底取消人为权重置顶，严格按 A–Z 纯字母顺序排列**）、`"custom"`、`"developer"`、`"format"` 与 `"flat"` 五种视图模式；分组模式下先完成全量分桶再按单组截断，确保大规模插件库下不丢失任何分组或自定义分组条目。
  - **上下双区跨区双向移动 FX**：实现 `core.move_normal_fx_to_strip(tr, from_visual_slot, to_strip_slot_1based)`（当 0 号位 Strip 未初始化时自动创建容器并移入指定或末尾槽位）与 `core.move_strip_fx_to_normal(tr, from_strip_slot_1based, to_visual_slot)`（从 0 号位容器移出至下半区指定视觉槽位或末尾；即使插入至常规槽 1 号位或移空全部子插件，也严格保证 0 号位容器本体稳居 `top_index 0` 不被挤占、覆盖或误删）。
  - **单行 Wet/Dry 原生干湿比参数读写**：实现 `core.get_fx_wet_param_index(tr, fx_id)`（优先调用 `TrackFX_GetParamFromIdent(tr, fx_id, ":wet")`，自动向下兼容回退 `TrackFX_GetNumParams` + `TrackFX_GetParamName("Wet")`）、`core.get_fx_wet(tr, fx_id)` 与 `core.set_fx_wet(tr, fx_id, wet_0_to_1, record_undo, pre_undo_wet_0_to_1)`；支持顶层常规插件与 `0x2000000+` 容器子插件的干湿比读写、`[0.0, 1.0]` 边界夹紧、NaN/越界拦截及拖拽过程中的按需 Undo 控制。
- **`tests/mock_reaper.lua` & `tests/run.lua`（单元测试套件扩展至 13 组）**：
  - 在 `mock_reaper.lua` 中新增 `EnumInstalledFX`、`mock_set_installed_fx`、`GetResourcePath`、`mock_set_resource_file`、`mock_read_resource_file`、`TrackFX_GetParamFromIdent(":wet")`、`TrackFX_GetNumParams`、`TrackFX_GetParamName`、`TrackFX_GetParam`、`TrackFX_SetParam` 及节点 `wet` 状态跨容器复制/移动保持。
  - 在完整保留前 10 组单元测试的基础上，新增用例 11（Synth 虚拟乐器识别、默认过滤与按需包含切换）、用例 12（`reaper-fxfolders.ini` 文件夹与智能文件夹、`reaper-fxtags.ini`、多维分组与脚本内自定义分组 `ExtState` 持久化）、用例 13（上下双区跨区互相拖拽移入/移出、未初始化自动建容器、干湿比保持与 0 号位容器防挤占/防误删保护）。
- **`src/ui.lua`（朴素 ImGui 默认控件接通 `v0.2.0` 完整操作闭环与三大增强）**：
  - **双区独立 `+ 添加` 插件分组搜索弹窗**：默认勾选隐藏 Synth 乐器插件（提供 `显示乐器/合成器 (VSTi/CLAPi)` 切换开关）；默认启用折叠树状分组视图（带 `###tree_grp` 稳定节点 ID 与搜索词变更单次自动展开），支持一键切换 `[分类]` / `[自定义/文件夹]` / `[厂商]` / `[格式]` / `[平铺]`，支持在弹窗内直接新建/删除自定义分组并在任意插件上右键加入/移出自定义分组。
  - **区内与上下跨区双向拖拽排序及右键菜单**：统一使用 `REAPCH_DND_FX` 拖拽载荷，支持在区内拖拽排序、将下半区常规 FX 拖入上半区具体子槽位或区域标题/空白处/末尾追加行（未初始化 Strip 时自动建容器并移入）、将上半区 Strip 子插件拖出至下半区常规槽位或标题/空白处/末尾追加行；每行右键菜单同步提供 `移入 0 号位 Channel Strip (▲)` / `移出至常规 FX 槽 (▼)`。
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
2. **双区卡片排版、单行 MIX 旋钮（Knob）化与拖拽视觉反馈精修**（预估复杂度：**中**）：
   - 紧凑单行间距、Bypass 状态指示灯、拖拽目标插入高亮线。
   - **单行 MIX（Wet/Dry 干湿比）改为紧凑旋钮（Knob）形式**：在 UI 精修阶段将当前朴素横向拉条（`SliderInt`）替换为 `ImDrawList` 绘制的紧凑圆弧旋钮（Knob），不采用拉条形式。
   - 保留 REAPER / ReaImGui 原生 Docking 与 Split Dock 停靠特性，不做人为限制或取消。

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
1. 在 REAPER 7 内运行 `tests/run.lua` 验收全部 13 组单元测试，并在 `src/main.lua` 中实机体验：
   - `+ 添加` 弹窗默认过滤 Synth 乐器插件、多维分组浏览（`分类` / `自定义/文件夹` / `厂商` / `格式` / `平铺`）与自定义分组右键归类；
   - 上下双区之间互相拖拽 FX（或右键菜单一键跨区移入/移出）。
2. 触发 UI 建构门禁：由用户决定是否立即推进 `src/theme.lua` Studio Dark 配色与双区视觉精修，或先搁置视觉直接推进 `v0.3.0` Strip 预设管理。
