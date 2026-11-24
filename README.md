# Reaper ProChannel (`ReaPCh`)

**Reaper ProChannel (`ReaPCh`)** 是一款运行于 **REAPER 7.06+** 的轻量级 **Lua ReaScript**（基于 **ReaImGui**）。  
核心形态为**可停靠（Dockable）在宿主左侧的极简双区 FX Inspector**，选中任意轨道即自动切换至该轨道的双区插件视图。

---

## 当前版本：`v0.1.0`（核心骨架 + 朴素双区 MVP）

### 已实现特性（`v0.1.0`）
1. **上半区：0 号位 · Channel Strip（音色塑形区）**
   - 基于 REAPER 7 原生 `FX Container`（默认命名为 `◆ CHANNEL STRIP ◆`）承载任意第三方 VST2 / VST3 / CLAP / JSFX。
   - **GUID 认亲机制**：通过轨道扩展元数据 `P_EXT:REAPCH_STRIP_GUID` 持久化绑定容器 GUID，绝不硬编码 `index == 0`。
   - **按需初始化**：未初始化轨道不强制自动建容器，点击 `[+ 初始化 0 号位 Strip]` 按需创建。
   - **平铺展开与控制**：直接平铺列出容器内所有子插件，支持**整区总 Bypass**、**单行独立 Bypass** 以及**点击插件名直接弹出/隐藏原生 VST 悬浮窗**。
2. **下半区：常规 FX 槽（视觉从 `1..N` 编号）**
   - 自动过滤并隐藏 0 号位 Strip 容器本体，其余常规插件按真实信号流顺序从 `1, 2, 3...` 重新编号展示。
   - 支持单行 Bypass 与点击名称切换悬浮窗。
   - 核心逻辑层内置严格的索引映射与边界拦截保护，防止下半区排序或删除操作越界误伤 0 号位容器。
3. **MCP 手滑偏离检测与归位**
   - 当 0 号位容器在原生 MCP / FX Chain 中被误拖离顶层 `index 0` 时，仍按 GUID 准确识别且绝不误认位于 `index 0` 的普通插件。
   - 默认显示温和提示条 `⚠ Strip 不在信号链最前端（当前位置 #X）` 与 `[一键归位]` 按钮；支持在右上角 `⚙` 设置菜单中开启 `Auto-Snap Strip to Slot 0` 自动归位。
   - 若容器在原生界面被手动删除，优雅降级回退至未初始化状态。
4. **零空转扫描防抖**
   - 主循环基于 `reaper.GetProjectStateChangeCount(0)` 与当前选中轨道指针（`reaper.GetSelectedTrack(0, 0)`）做变化检测，空转帧零 FX 扫描开销。

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
