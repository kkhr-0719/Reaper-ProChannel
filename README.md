# Reaper ProChannel (`ReaPCh`)

**Reaper ProChannel (`ReaPCh`)** 是一款运行于 **REAPER 7.06+** 的轻量级 **Lua ReaScript**（基于 **ReaImGui**）。  
核心形态为**可停靠（Dockable）在宿主左侧的极简双区 FX Inspector**，选中任意轨道即自动切换至该轨道的双区插件视图。

---

## 当前版本：`v0.2.0`（完整操作闭环 + 朴素 ImGui 默认布局）

### 已实现特性（`v0.2.0`）
1. **上半区：0 号位 · Channel Strip（音色塑形区）**
   - 基于 REAPER 7 原生 `FX Container`（默认命名为 `◆ CHANNEL STRIP ◆`）承载任意第三方 VST2 / VST3 / CLAP / JSFX。
   - **GUID 认亲机制**：通过轨道扩展元数据 `P_EXT:REAPCH_STRIP_GUID` 持久化绑定容器 GUID，绝不硬编码 `index == 0`。
   - **按需初始化与直通添加/拖入**：未初始化轨道不强制自动建容器，可点击 `[+ 初始化 0 号位 Strip]` 按需创建，或直接点击上半区 `[+ 添加]` 挑选插件、**直接将下半区常规插件拖入上半区**（自动先建容器再置入插件，失败时自动原子回滚）。
   - **平铺展开与全套单行控制**：直接平铺列出容器内所有子插件，支持**整区总 Bypass**、**单行独立 Bypass**、**点击插件名弹出/隐藏原生 VST 悬浮窗**、**单行 `0%..100%` Wet/Dry 干湿比滑条**、**区内与跨区双向拖拽排序 / 右键上下移动及跨区移出**与**右键 / `×` 快捷移除**。
2. **下半区：常规 FX 槽（视觉从 `1..N` 编号）**
   - 自动过滤并隐藏 0 号位 Strip 容器本体，其余常规插件按真实信号流顺序从 `1, 2, 3...` 重新编号展示。
   - 支持独立 `[+ 添加]` 搜索添加插件、单行 Bypass、点击名称切换悬浮窗、单行 Wet/Dry 干湿比调节、区内拖拽排序、**与上半区 0 号位 Strip 双向跨区拖拽（或右键菜单一键移入 0 号位 Strip）**、右键菜单与 `×` 快捷移除。
   - 核心逻辑层严格保护 0 号位容器本体，无论跨区移入还是移出至常规槽 1 号位，均严禁误删、挤占或覆盖 0 号位容器。
3. **双区独立 `+ 添加` 分组浏览器弹窗（默认过滤 Synth 乐器 + 4 个 `DXi:` 效果器豁免 + 运行内 DX 刷新兜底 + 支持自定义分组）**
   - **默认过滤 Synth 虚拟乐器与 `DXi:` 效果器豁免**：由于 REAPER 不区分音频轨与乐器轨，`EnumInstalledFX` 会同时返回效果器与合成器；弹窗默认自动过滤掉 `VSTi` / `VST3i` / `CLAPi` / `AUi` / `LV2i` / `DXi` 及 `reaper-fxtags.ini` 标记为 `Instrument` 的乐器插件（弹窗内提供 `显示乐器/合成器 (VSTi/CLAPi)` 复选框可按需开启），同时对被 REAPER 标为 `DXi:` 的 4 个已知音频效果器（`Sonitus:fx Delay`、`Cakewalk Tempo Delay`、`Cakewalk Classic Phaser`、`Cakewalk Modfilter`）内置硬编码豁免放行。
   - **运行内新扫描 DX 插件刷新兜底**：点击弹窗内 `[刷新]` 时自动调用 `EnumInstalledFX(-1)` 并增量解析合并 `reaper-dxplugins64.ini` / `reaper-dxplugins.ini` 中已启用（`Load ~= 0`）的 DX 插件，无需重启 REAPER 即可刷出运行中途新扫到的 DX 插件。
   - **多维分组（严格 A–Z 分类排序）与 REAPER 原生文件夹联动**：默认启用树状分组视图，自动读取 REAPER 资源目录下的 `reaper-fxfolders.ini`（含自定义文件夹与智能文件夹）和 `reaper-fxtags.ini`（分类与厂商标签），支持在 **`[分类]` / `[自定义/文件夹]` / `[厂商]` / `[格式]` / `[平铺]`** 五种视图间一键切换；功能分类严格按 **A–Z 纯字母顺序**排列（不强插人为置顶权重），且兜底分类与 REAPER 原生分类名（`EQ`、`Filter`、`Dynamics`、`Reverb`、`Delay`、`Distortion`、`Modulation`、`Channel Strip`、`Utility`、`Analyzer`、`Other FX`）统一合并，不出现重复分类。
   - **Cakewalk 风格脚本内自定义分组**：点击弹窗内 `[+ 自定义分组]` 可直接新建自定义分组（如 `常用话放`、`鼓组塑形`），在列表中**右键点击任意插件**即可将其加入或移出自定义分组（配置通过 `ExtState` 持久化保存，并自动置顶在分类视图最上方）。
   - 支持空格分词多关键词即时检索（可同时匹配插件名、标识符、厂商名与分类名）、一键清空搜索词与手动刷新插件缓存。
4. **MCP 手滑偏离检测与归位**
   - 当 0 号位容器在原生 MCP / FX Chain 中被误拖离顶层 `index 0` 时，仍按 GUID 准确识别且绝不误认位于 `index 0` 的普通插件。
   - 默认显示温和提示条 `⚠ Strip 不在信号链最前端（当前位置 #X）` 与 `[一键归位]` 按钮；支持在右上角 `⚙` 设置菜单中开启 `Auto-Snap Strip to Slot 0` 自动归位。
   - 若容器在原生界面被手动删除，优雅降级回退至未初始化状态。
5. **零空转扫描防抖与友好 Undo 控制**
   - 主循环基于 `reaper.GetProjectStateChangeCount(0)` 与当前选中轨道指针（`reaper.GetSelectedTrack(0, 0)`）做变化检测，空转帧零 FX 扫描开销。
   - 单行 Wet/Dry 滑条在拖拽过程中实时改变音频参数而不刷屏 Undo 历史，仅在松手结束拖拽时记录一条干净的 Undo 块。

---

## 环境要求

- **REAPER**：`v7.06` 或更高版本（需支持 REAPER 7 原生 FX Container 编址 API）
- **ReaImGui**：`v0.9` / `v0.10+`（通过 ReaPack 安装 `ReaImGui: ReaScript binding for Dear ImGui`）

---

## 安装与使用

1. 打开 REAPER，按 `?` 打开 **Actions（动作列表）**。
2. 点击右下角 **New Action... -> Load ReaScript...**，选择本项目下的 `src/main.lua`。
3. 运行该 Action 即可打开 **Reaper ProChannel** 面板。

### 如何将窗口停靠（Dock）到 REAPER 左侧
由于 ReaImGui 窗口采用 Dear ImGui 自身标题栏而非 REAPER 原生系统标题栏，停靠方式与原生窗口略有不同，支持以下两种方式：

1. **方式一：面板内一键停靠（推荐）**
   - 点击面板右上角 `⚙` 设置按钮，点击 **`[一键停靠至 REAPER Docker]`**，窗口将立即并入 REAPER Docker（已停靠时再次打开 `⚙` 可点击 **`[脱离停靠 (恢复浮动窗口)]`**）。
   - 若停靠后 Docker 位于底部或其他位置：在 REAPER Docker 底部标签栏空白处（或感叹号 `!` 菜单）**右键 -> `Attached Docker position: Left`**，即可将该 Docker 固定在 REAPER 主界面左侧。
2. **方式二：拖拽标题栏至边缘蓝色热区**
   - 按住 `Reaper ProChannel` 顶部标题栏向 REAPER 主窗口**最左侧边缘**（或已有 Docker 区域）拖动，屏幕边缘会浮现**半透明蓝色停靠指示框**，将鼠标移入左侧蓝框后松开即可完成停靠。
   - *注：若在 `Options -> Preferences -> Plug-ins -> ReaImGui` 中勾选了 `Dock only when holding Shift`，则拖动标题栏时需同时按住 **`Shift` 键**才会出现蓝色停靠框。*

---

## 单元测试

核心逻辑层 `src/core.lua` 与 UI 完全解耦，支持以下两种方式运行单元测试套件（`tests/run.lua`）：

1. **命令行运行**（需系统 `PATH` 已配置 Lua 5.3/5.4 解释器）：
   ```bash
   lua tests/run.lua
   ```
2. **REAPER 内置 Lua 5.4 运行**（无需额外安装命令行 Lua）：
   - 在 REAPER **Actions -> Load ReaScript...** 中加载并运行 `tests/run.lua`。
   - 脚本会自动隔离真实宿主环境、使用 `tests/mock_reaper.lua` 执行全部边界测试，并将测试报告输出至 ReaScript 控制台窗口。

---

## 目录结构

```text
ReaperProChannel/
├── AGENTS.md             # 开发宪法与协作纪律
├── DEVLOG.md             # 实时进度、Bug 与搁置项交接板
├── README.md             # 用户安装与使用说明
├── docs/
│   ├── SPEC.md           # 产品与技术规格书
│   └── imgui.lua         # 本机 REAPER 导出的官方 ReaImGui 垫片源码
├── src/
│   ├── main.lua          # 入口脚本：环境检测、ReaImGui 上下文、defer 主循环、状态防抖
│   ├── core.lua          # 【纯逻辑层】GUID 认亲、容器编址、视图模型生成、移动/增删边界保护
│   ├── ui.lua            # 【薄渲染层】消费 core.lua 输出的数据，绘制双区界面、设置菜单与交互
│   └── theme.lua         # 配色与布局常量骨架（v0.2.0 触发 UI 建构门禁后定型 Studio Dark）
└── tests/
    ├── mock_reaper.lua   # 纯 Lua 模拟 REAPER 轨道、FX、Container、GUID 与 P_EXT 的测试桩
    └── run.lua           # 一键单元测试入口
```
