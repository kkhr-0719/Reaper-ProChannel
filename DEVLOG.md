# DEVLOG.md

- **当前版本**：`v0.2.0`（含 `v0.2.1` UI 调试与质感精修迭代：完整操作闭环 + Studio Dark / 浅色粉红等宿主 HSL 自适应视觉体系 + 单行 MIX 圆弧旋钮与像素级防溢出卡片；遵循全局版本号锁死规则，未正式打 Tag / Release 前 `core.VERSION` 保持 `0.2.0` 不变）
- **项目简称**：`ReaPCh`（Reaper ProChannel）
- **前置环境**：
  - `docs/imgui.lua`：已确认，本机 ReaImGui 动态垫片（`reaper_imgui-x64` `v0.10.0.5`），支持 `require 'imgui' '0.10'`（向下兼容 `'0.9'`）；垫片在加载时已对 `flags & 1 ~= 0` 的枚举常量预求值，且遵循 ReaImGui 0.9/0.10 规范仅在 `ImGui.Begin` / `ImGui.BeginChild` 返回 `visible == true` 时调用 `ImGui.End` / `ImGui.EndChild`。
  - `tests/run.lua`：`v0.1.0` 7 组边界测试已在 REAPER 7 宿主内置 Lua 5.4 环境中实机验证全部 PASS；现已扩展至 **17 组**边界与 UI 集成单元测试用例（含用例 14b 白/浅灰+樱花粉宿主 HSL 色相保持与第三方位图占位黑容错、用例 15 严格 `docs/imgui.lua` 元表下 `ui.draw` 全流程栈平衡与 UTF-8 截断、用例 16 中灰 WCAG 兜底/MIX 旋钮状态机/超窄窗与拖拽 Tooltip 防穿透，以及用例 17 全灰度 0..255 边界中灰与中浅灰完整表面对比度、`Col_DragDropTarget` + `AcceptNoDrawDefaultRect` 去默认黄框与顶层 DnD Z-Order 顺序、旋钮 1.5px 防手抖/跨行 Hover 隔离、拖拽取消防误开窗及 120px 极窄按钮收敛回归）。
  - **Git 仓库状态**：当前在 `feat/v0.2.1-ui-polish` 分支（基于已同步远端的 `origin/feat/v0.2.0-core-loop`）；用户已实机验收 `v0.2.1` UI 并下令推送，现已同步推送至 `origin/feat/v0.2.1-ui-polish`，同时将 `README.md` 更新为精简版中日英三语文档并补充 `v0.1.0` / `v0.2.0` / `v0.2.1` 精简版本记录（未获用户明确合并指令前不合并回 `main`）。

## 已完成（`v0.2.1` UI 调试、缺陷修复与质感精修）
- **`src/theme.lua`（HSL 宿主彩色点缀承接、浅色主题清爽层次、极端中灰数学兜底与完整 ImGui 控件染色）**：
  - **纯 Lua RGB ↔ HSL 色相保持算法（`theme.rgb_to_hsl` / `hsl_to_rgb` / `adapt_vivid_accent`）**：在多组 REAPER 主题高亮键（`col_tcp_bgsel`、`col_seltrack2`、`col_seltrack`、`col_main_hilite`、`col_tl_bgsel`、`selitem_dot` 等）中优先捕获有效彩色点缀（含极淡樱花粉 `L > 0.85, spread >= 10, S >= 0.22`），仅沿 HSL 亮度轴调整至满足对比度门槛并优雅控制饱和度上限（浅底 `0.78` / 深底 `0.82`），彻底杜绝浅色粉红变脏发灰、过曝刺眼或回退硬编码冷蓝的问题；当宿主色相落入暖琥珀区（`20°..52°`）时自动错开 0 号位 Strip 强调色以保证双区一眼可辨。
  - **WCAG 2.1 全色域同侧数学兜底与独立标题语义色**：将 `theme.LIGHT_LUMINANCE_THRESHOLD` 精确校准至 WCAG 黑白等对比度平衡点 `0.179`，并通过 `clamp_surface_luminance` 与 `ensure_contrast_all` 约束所有派生背景稳居同侧，彻底根治中灰宿主皮肤（`L ∈ (0.179, 0.22]`）下链式对比度翻转与中浅灰皮肤（如 `RGB(145,145,148)`）双区标题栏对比度跌破 2.1 的缺陷；新增独立 `strip_zone_title` / `normal_zone_title` 与 `popup_title_strip` / `popup_title_normal` 语义色并补齐 `host_dark` 下 `master_off_text` / `row_bg_hover` / `header_bar_bg` 校验（经全灰度 `0..255` × 5 强调色共 1,280 套调色板数学验证 0 失败）。
  - **第三方 PNG 位图浅色皮肤占位黑容错**：当 `col_main_bg2` 为极暗占位黑（`L < 0.02`）而 `col_tcp_bg` 与 `col_main_editbk` 均为明亮浅色（`L > 0.45`）时，自动采用 `col_tcp_bg` 判定为 `host_light`，避免误判为纯黑皮肤。
  - **完整 ImGui 原生控件配色栈补齐 + 零每帧分配缓存**：补全 `Col_Scrollbar*`、`Col_Tab*`（`rawget` 优先 0.10 `Col_TabSelected`/`Col_TabDimmed` 回退 0.9 `Col_TabActive`/`Col_TabUnfocused` 且双键并存不重复压栈）、`Col_TextSelectedBg`、`Col_ResizeGrip*`、`Col_DockingPreview`、`Col_TitleBgCollapsed`、`Col_DragDropTarget` 等；`theme.pop` 自动清空 `theme._active_palette` 防止帧外读到过期主题；默认 Studio Dark 与宿主主题均采用签名/实例缓存（`theme.clear_host_cache()`），兼顾零每帧 GC 与换肤即时响应。
- **`src/ui.lua` & `src/main.lua`（实机级布局修复、防溢出截断、交互手感与 Split Dock 兼容）**：
  - **彻底消除单行 FX 卡片 `Selectable` 脏框、超窄横滚与长插件名/百分比溢出**：将单行 FX 卡片升级为精确 4 段式像素对齐布局（左侧 3px 色条 + 18px Bypass LED + 弹性插件名热区 + 动态宽度 MIX 旋钮 + 20px 硬件风格 `×` 移除钮），新增按 UTF-8 字符边界安全截断的 `fit_text_with_ellipsis` 与 `DrawList_PushClipRect/PopClipRect` 双重防溢出；宽度下限放宽至 `120px` 消除窄窗横滚条，并在窄 Split Dock（`< 196px`）自动切换 MIX 旋钮为纯圆弧紧凑模式优先保证插件名可读（悬停仍显示精确百分比 Tooltip），常规宽度下为旋钮外环与 `"100%"` 留足呼吸间距；叠加 `IsWindowHovered` 阻断弹窗/菜单遮挡穿透，并在拖拽某行 MIX 旋钮期间通过 `ui._active_knob_row_id` 抑制经过其他行的误高亮；无选中轨道提示亦自动换行防横滚。
  - **`BeginGroup` 垂直居中按钮与固定吸顶轨道栏**：新增 `render_centered_button` 利用 `BeginGroup`/`EndGroup` 隔离 `SetCursorPosY`，彻底消除标题栏/轨道栏/偏离卡片底部 `+2px` 幽灵行距漂移并规避 Dear ImGui 1.91 越界断言；顶部 `TRK` 轨道栏固定吸顶且超长轨道名自动截断（绝不挤出右上角 `⚙` 按钮）；下方双区置于无边框透明 `BeginChild("##reapch_body_scroll", 0, 0)` 中流畅滚动，完整保留 REAPER / ReaImGui 原生 Split Dock；通过 `ui._pending_open_fx_browser` 在顶层主窗口 ID 栈统一调用 `OpenPopup`，彻底避免 `BeginChild` 子作用域导致点击 `+ 添加` 打不开弹窗的 Bug。
  - **`+ 添加` 弹窗排版锁宽精修**：弹窗列表 `BeginChild` 自动启用 `ChildFlags_Borders`（0.10）/ `ChildFlags_Border`（0.9）清晰描边，右对齐 `[+ 自定义分组]` 按钮至 `390px` 边缘，新建分组输入框支持 `Enter` 回车快捷提交，并对顶部统计文字、自定义分组编辑器提示与树节点空组/截断提示全面启用 `PushTextWrapPos`/`PopTextWrapPos` 自动换行，杜绝弹窗横向撑宽或列表内横滚条。
  - **双区标题栏、去默认黄框顶层三态拖放反馈与拖拽 Tooltip 抑制**：消除原标题栏 `Selectable` 丑框与超窄 Split Dock 按钮破框（`< 170px` 自动切紧凑 `+` 按钮、偏离卡 `< 160px` 自动切紧凑 `归位`、未初始化按钮按宽收敛文案），将 0 号位整区总 Bypass 升级为紧凑硬件胶囊开关（`ON` / `OFF`），将 MCP 偏离提示条升级为带 `warning_bg` / `warning_border` 的卡片；`attach_zone_drop_target` 探测传入 `DragDropFlags_AcceptNoDrawDefaultRect` 屏蔽 Dear ImGui 默认亮黄小框，并通过 `defer_draw` 将整行与标题栏的高亮底色/插入线延迟至全部子控件绘制完毕后的最顶层统一绘制，彻底消灭 Z-Order 遮挡撕裂；拖拽取消回到自身松手时自动拦截防误弹插件悬浮窗；拖拽 FX 期间全局抑制 LED / 旋钮 / `×` / 胶囊 / 轨道栏的悬停 Tooltip 与光标闪烁，彻底杜绝污染 DragDropSource 预览窗；轨道切换自动清理 `_wet_*` 旋钮拖拽缓存。
  - **MIX 圆弧旋钮渲染与手感增强**：采用 28 段背景圆弧与按值自适应分段有效圆弧提升 HiDPI 顺滑度，新增悬停/拖拽外环高亮、拖拽态 `MouseCursor_ResizeNS` 上下调节光标与右对齐百分比读数，引入 `1.5px` 累计位移防手抖启动阈值（免疫双击前轻微手抖产生垃圾 Undo，同时不吞真实拖拽像素），保留上下拖拽实时调参不刷 Undo、`Shift` 4 倍微调、松手沿用 `pre_undo_wet_0_to_1` 基线一步 Undo、双击重置 `100%`（已是 `100%` 时不产生空 Undo）。
  - **`src/main.lua`**：将 `ConfigFlags_DockingEnable` 改为 `rawget` 探测，统一全项目防 `__index` 抛错规范。
- **`tests/run.lua`（扩展至 17 组单元测试）**：
  - 保留全部前 16 组用例，新增用例 17：覆盖中灰 (`122`) / 中浅灰 (`145`) / 暗灰+亮强调色全表面 WCAG `>= 4.5` 与独立标题栏/弹窗标题对比度、`Col_DragDropTarget` 压栈与 `theme.pop` 清空 `_active_palette`、`DragDropFlags_AcceptNoDrawDefaultRect` 去默认黄框与顶层 DnD Z-Order 顺序验证、拖拽取消防误开窗、旋钮 `1px` 防手抖不写垃圾 Undo + 跨行 Hover 隔离，以及 `120px` 极窄 Split Dock 紧凑 `+` 按钮与换行栈平衡校验。

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
1. 待用户明确下令后再将验收通过的 `feat/v0.2.1-ui-polish` 合并回 `main` 或打 Release Tag。
2. 推进 `v0.3.0`：0 号位 Channel Strip 预设保存与加载体系（`RfxChain` / 容器预设复用）。
