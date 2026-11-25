# Reaper ProChannel (`ReaPCh`)

面向 **REAPER 7** 的轻量级左侧可停靠双区 FX Inspector（Lua ReaScript / ReaImGui），选中任意轨道即自动同步该轨道的插件链视图。

## 环境要求

- **REAPER** `7.06+`
- **ReaImGui** `0.9+`（通过 ReaPack 安装）

## 安装与停靠

1. 在 REAPER 中按 `?` 打开 **Actions**。
2. 点击 **New Action... → Load ReaScript...**，加载 `src/main.lua`。
3. 运行该 Action 打开面板。

**停靠至左侧 Docker**：点击面板右上角 `⚙` → **一键停靠至 REAPER Docker**（若 Docker 不在左侧，右键 Docker 标签栏空白处 → `Attached Docker position: Left`），或直接拖动标题栏至主窗口左边缘蓝框（若开启了 ReaImGui 的 `Dock only when holding Shift`，拖动时按住 `Shift`）。

## 核心功能

- **双区插件视图**：上半区为基于 REAPER 7 原生 FX Container 的 **0 号位 Channel Strip**（按需初始化，平铺展开内部插件并支持整区总 Bypass）；下半区为常规 FX 槽（自动隐藏 Strip 容器并按 `1..N` 编号）。
- **单行快捷操控**：支持单行 Bypass 指示灯、点击插件名开关原生悬浮窗、单行 MIX 干湿比圆弧旋钮（上下拖拽调节、`Shift` 微调、双击重置 `100%`）、快捷移除，以及区内/跨区双向拖拽排序。
- **分组插件搜索**：双区独立 `+ 添加` 弹窗，默认过滤乐器插件，支持多关键词检索、按分类 / REAPER 文件夹 / 厂商 / 格式切换及右键自定义分组。
- **界面与主题**：默认 Studio Dark 深色主题，可在右上角 `⚙` 开启实验性跟随 REAPER 宿主主题配色（兼容浅色与深色皮肤），并支持 Strip 偏离 0 号位检测与一键归位。
