# DEVLOG.md

- **当前版本**：`v0.2.0`（完整操作闭环 + Studio Dark / 宿主自适应视觉体系 + 单行 MIX 圆弧旋钮；遵循全局版本号锁死规则，未正式打 Tag / Release 前保持 `v0.2.0` 版本号不变）
- **项目简称**：`ReaPCh`（Reaper ProChannel）
- **前置环境**：
  - `docs/imgui.lua`：已确认，本机 ReaImGui 动态垫片（`reaper_imgui-x64` `v0.10.0.5`），支持 `require 'imgui' '0.10'`（向下兼容 `'0.9'`）；垫片在加载时已对 `flags & 1 ~= 0` 的枚举常量预求值，且遵循 ReaImGui 0.9/0.10 规范仅在 `ImGui.Begin` / `ImGui.BeginChild` 返回 `visible == true` 时调用 `ImGui.End` / `ImGui.EndChild`。
  - `tests/run.lua`：`v0.1.0` 7 组边界测试已在 REAPER 7 宿主内置 Lua 5.4 环境中实机验证全部 PASS；`v0.2.0` 现已扩展至 **14 组**边界单元测试用例（新增 `EnumInstalledFX` 枚举缓存与搜索、单行 Wet/Dry 原生参数读写、双区双向排序、**Synth 乐器插件识别与默认过滤**、**`reaper-fxfolders.ini` / `reaper-fxtags.ini` 解析与多维分组 + 脚本内自定义分组持久化**、**上下双区跨区互相拖拽移入/移出与 0 号位容器保护**、**`src/theme.lua` 颜色打包/解包与 `GetThemeColor` 转换、WCAG 2.1 对比度兜底、浅色/深色宿主主题自适应及 ImGui 样式栈压弹平衡**）。
  - **Git 远程仓库核验记录**：当前本地仓库尚未绑定远程仓库 URL（`git remote -v` 为空），暂无法执行 `git push`；所有提交均规范保存在本地 `feat/v0.2.0-core-loop` 分支。

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
- **`tests/mock_reaper.lua` & `tests/run.lua`（单元测试套件扩展至 14 组）**：
  - 在 `mock_reaper.lua` 中新增 `EnumInstalledFX`、`mock_set_installed_fx`、`GetResourcePath`、`mock_set_resource_file`、`mock_read_resource_file`、`TrackFX_GetParamFromIdent(":wet")`、`TrackFX_GetNumParams`、`TrackFX_GetParamName`、`TrackFX_GetParam`、`TrackFX_SetParam` 及节点 `wet` 状态跨容器复制/移动保持，并新增 `GetThemeColor`、`ColorFromNative`、`ColorToNative` 与 `mock_set_theme_colors`。
  - 在完整保留前 10 组单元测试的基础上，新增用例 11（Synth 虚拟乐器识别、默认过滤与按需包含切换）、用例 12（`reaper-fxfolders.ini` 文件夹与智能文件夹、`reaper-fxtags.ini`、多维分组与脚本内自定义分组 `ExtState` 持久化）、用例 13（上下双区跨区互相拖拽移入/移出、未初始化自动建容器、干湿比保持与 0 号位容器防挤占/防误删保护）、用例 14（`theme.lua` `0xRRGGBBAA` 打包/解包、`GetThemeColor` + `ColorFromNative` 转换、WCAG 2.1 相对亮度与对比度安全兜底、明亮白/浅灰底浅色主题与深色主题自适应及严格元表下 `theme.push` / `theme.pop` 样式栈平衡）。
- **`src/theme.lua`（Studio Dark 默认独立深色主题 + REAPER 宿主主题配色自适应与对比度安全兜底）**：
  - **Studio Dark 独立深色主题**：提供低饱和中性深色配色栈、4px/3px 圆角与紧凑间距变量；为上半区 `0 号位 · Channel Strip` 定制暖琥珀金强调色与卡片底色，为下半区 `常规 FX 槽 (1..N)` 定制录音室冷蓝强调色与卡片底色。
  - **跟随 REAPER 宿主主题配色（实验性，自动兼容浅色与深色皮肤）**：通过 `reaper.GetThemeColor()` 读取 `col_main_bg2` / `col_tcp_bg` / `col_main_text2` / `col_main_editbk` / `col_tcp_bgsel`，并通过 `reaper.ColorFromNative()` 准确转换为 ReaImGui `0xRRGGBBAA` 格式；基于 WCAG 2.1 相对亮度（`theme.relative_luminance`）自动识别明亮白/浅灰底浅色宿主主题（`host_light`）与深色宿主主题（`host_dark`），并通过 `theme.ensure_contrast`（默认对比度门槛 `>= 4.5`）对主背景、双区卡片、按钮、输入框与弹窗文字做对比度安全兜底，彻底防止第三方 PNG 位图皮肤缺失文字色配置导致文字不可读。
  - **严格 `rawget` 探测与压弹栈平衡**：`theme.push` 对每一个 `Col_*` 与 `StyleVar_*`（区分单浮点标量与双浮点 `ImVec2`）一律通过 `rawget(ImGui, ...)` 探测，精确返回压栈计数并与 `theme.pop` 100% 匹配。
- **`src/ui.lua`（双区卡片视觉精修、单行 MIX 圆弧旋钮化与拖拽高亮插入线）**：
  - **单行 MIX（Wet/Dry 干湿比）紧凑圆弧旋钮（Knob）**：基于 `ImGui.GetWindowDrawList`（`DrawList_PathArcTo` + `DrawList_PathStroke` / `DrawList_AddCircleFilled` / `DrawList_AddLine` / `DrawList_AddText`）绘制 270° 圆弧旋钮与紧凑百分比读数，通过 `ImGui.InvisibleButton` 承接交互；支持鼠标上下拖拽实时调参不刷屏 Undo、按住 `Shift` 4 倍精细微调、松手时沿用 `pre_undo_wet_0_to_1` 拖拽前基线恢复确保 `Ctrl+Z` 一步退回、双击快速重置为 `100%`、悬停与拖拽时 Tooltip 显示精确百分比与操作提示。
  - **双区卡片层级、左侧微细色条与硬件感 Bypass 指示灯**：双区标题栏与每行 FX 均采用圆角卡片容器 + 左侧 3px 区域强调色竖条（0 号位暖琥珀金 vs 常规槽冷蓝，旁通时自动降暗）；单行 Bypass 采用带发光光晕与灯座底盘的硬件感 LED 指示灯，旁通态（或 0 号位整区总 Bypass 时）自动切换低对比度文字，插件悬浮窗开启时高亮行卡片底色与外框。
  - **跨区/区内拖拽高亮插入指示线反馈**：拖拽悬停在目标行或区域标题/空白/末尾追加区时，实时计算落点位置并在目标行顶部或底部绘制高亮水平插入线、两端圆点标识与半透明热区底色；完整保留 REAPER / ReaImGui 原生 Docking 与自由分栏（Split Dock）特性。
  - **双区独立 `+ 添加` 插件分组搜索弹窗与双向跨区流转**：默认勾选隐藏 Synth 乐器插件（含 4 个 `DXi:` 音频效果器硬编码豁免与运行内 DX INI 增量刷新兜底），支持 `[分类]` / `[自定义/文件夹]` / `[厂商]` / `[格式]` / `[平铺]` 视图切换与右键自定义分组管理。

## 已完成（`v0.1.0` 基础回顾）
- 0 号位容器 `P_EXT:REAPCH_STRIP_GUID` 持久化认亲、按需初始化（`◆ CHANNEL STRIP ◆`）、手动删容器优雅降级、MCP 手滑偏离检测与一键/自动归位。
- REAPER 7.06+ `0x2000000+` 容器编址正反解、下半区隐藏容器与 `1..N` 视觉重编号映射、全套边界硬拦截。
- ReaImGui `0.10`/`0.9` 可停靠上下文、`GetProjectStateChangeCount` 零空转扫描防抖循环及右上角 `⚙ -> [一键停靠至 REAPER Docker]`。

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
1. 在 REAPER 7 内运行 `tests/run.lua` 验收全部 14 组单元测试，并在 `src/main.lua` 中实机体验：
   - 默认 Studio Dark 主题与右上角 `⚙ -> 跟随 REAPER 宿主主题配色 (实验性)` 在明亮白/浅灰底浅色主题下的自适应卡片与文字对比度效果；
   - 单行 MIX 圆弧旋钮（上下拖拽、`Shift` 微调、双击重置 `100%`、松手 `Ctrl+Z` 一步退回、悬停 Tooltip）；
   - 双区卡片层级、Bypass 指示灯与跨区/区内拖拽高亮插入线反馈。
2. 待用户绑定远程仓库 URL 后执行 `git push`，或推进 `v0.3.0` 0 号位 Channel Strip 预设保存与加载体系。
