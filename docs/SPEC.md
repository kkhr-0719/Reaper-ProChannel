# SPEC.md — Reaper ProChannel (`ReaPCh`) 产品与技术规格书

## 1. 项目概述与形态

**Reaper ProChannel（`ReaPCh`）** 是一款运行于 **REAPER 7.06+** 的轻量级 **Lua ReaScript**（基于 **ReaImGui**）。  
核心形态为**可停靠（Dockable）在宿主左侧的极简双区 FX Inspector**，选中任意轨道即自动切换至该轨道的双区插件视图，无需操作原生混音台（MCP）上的扁平 FX 槽列表。

---

## 2. 功能规格（Features）

### 2.1 上半区：0 号位 · Channel Strip（音色塑形区）
- **底层载体**：轨道上的一个原生 **REAPER 7 FX Container**（默认显示名为 `◆ CHANNEL STRIP ◆`），作为 0 号位容器容纳任意第三方 VST2 / VST3 / CLAP / JSFX。
- **平铺展开**：侧边栏直接列出该 Container 内部的所有子插件，点击插件名直接弹出/隐藏对应 VST 原版悬浮窗，无需先打开原生 Container 树状窗口。
- **按需初始化**：选中尚未初始化 Strip 的轨道时，**不强制自动创建容器**；上半区显示 `[+ 初始化 0 号位 Strip]` 按钮（若用户直接点击上半区 `+` 添加插件，则自动先建容器再置入）。
- **整区控制**：上半区标题栏提供**整区总 Bypass 开关**（一键切换容器启用状态，用于快速 A/B 对比整条模拟链）与 `+` 添加入口。
- **单行控制**：每行包含独立 Bypass 开关、插件名称（点击切换悬浮窗显示）、区内拖拽排序与移除操作；`v0.2.0` 起可选提供轻量级单行 Wet/Dry 干湿比调节（复用 REAPER 原生 Wet 参数）。

### 2.2 下半区：常规 FX 槽（视觉从 1 号位起）
- **隐藏容器本体**：读取轨道顶层 FX 时自动过滤掉 0 号位 Strip 容器本身。
- **视觉重编号**：将剩余普通插件按真实信号流顺序展示，界面编号统一从 `1, 2, 3...` 递增。
- **严格边界隔离**：下半区的拖拽排序、插入与删除操作必须做索引映射与边界保护，**严禁误删或越界覆盖 0 号位容器**。

### 2.3 MCP 手滑偏离检测与归位策略
当用户在 REAPER 原生 MCP / FX Chain 窗口中误将 0 号位容器拖离顶层 `index 0` 时：
- **不发生误认**：侧边栏依然依据 GUID 准确将该容器渲染在上半区，绝不把碰巧位于 `index 0` 的普通插件当成 Channel Strip。
- **默认模式（温和提示）**：上半区顶部显示醒目提示条：`⚠ Strip 不在信号链最前端（当前位置 #X）[一键归位]`；点击后将其移回顶层 `index 0`。
- **可选模式（自动吸回）**：在设置菜单中提供 `Auto-Snap Strip to Slot 0` 开关（默认关闭）；开启后检测到偏离即自动移回 `index 0`。

### 2.4 配色与设置菜单（右上角 `⚙` 按钮）
在侧边栏标题栏右上角提供极简设置按钮 `⚙`（点击弹出轻量菜单），配置项通过 `reaper.SetExtState("REAPCH", key, val, true)` 持久化保存：
1. **默认独立深色主题（Studio Dark）**：使用 `src/theme.lua` 维护的低饱和中性深色配色，通过卡片底色与细微竖条区分上下双区层级。
2. **可选跟随宿主配色（实验性开关，默认关闭）**：设置菜单提供 `跟随 REAPER 宿主主题配色` 开关，开启时尝试通过 `reaper.GetThemeColor()` 读取背景与文字色；须附基础对比度安全兜底，防止第三方 PNG 位图皮肤配置缺失导致文字不可读。
3. **防手滑自动吸回开关**：控制上述 `Auto-Snap Strip to Slot 0` 行为（默认关闭）。

---

## 3. 范围边界（明确不做 / 暂缓项）

以下内容不属于当前版本范围，开发时须保持克制，严禁自行扩展：
- **不做第三方 VST 假旋钮 / 嵌入式伪 GUI**：所有插件参数调节均通过点击弹窗在原版 VST 界面内完成。
- **不做行内 Gain Reduction（GR）压缩电平条**：紧凑行高下缺乏刻度可读性，且不同格式插件上报兼容性不一致。
- **暂不做“单窗联动（点新关旧）”**：保留同时打开多个插件窗口对照微调的自由；若未来有需求再单独评估。

---

## 4. 目录结构与模块职责

```text
ReaperProChannel/
├── AGENT.md              # 开发宪法与协作纪律
├── DEVLOG.md             # 实时进度、Bug 与搁置项交接板
├── README.md             # 用户安装与使用说明
├── docs/
│   ├── SPEC.md           # 本文件（需求、范围与底层规范）
│   └── imgui.lua         # 本机 REAPER 导出的官方 ReaImGui 垫片源码
├── src/
│   ├── main.lua          # 入口脚本：环境检测、ReaImGui 上下文、defer 主循环、状态防抖
│   ├── core.lua          # 【纯逻辑层】GUID 认亲、容器编址、视图模型生成、移动/增删边界保护
│   ├── ui.lua            # 【薄渲染层】消费 core.lua 输出的数据，绘制双区界面、设置菜单与交互
│   └── theme.lua         # Studio Dark 配色、圆角/间距常量及可选宿主配色适配层
└── tests/
    ├── mock_reaper.lua   # 纯 Lua 模拟 REAPER 轨道、FX、Container、GUID 与 P_EXT 的测试桩
    └── run.lua           # 命令行一键测试入口（lua tests/run.lua）
```

---

## 5. REAPER 7 与 ReaImGui 底层技术规范

### 5.1 0 号位“GUID 认亲”机制（严禁硬编码 `index == 0`）
- **元数据键名**：`P_EXT:REAPCH_STRIP_GUID`（向下兼容读取 `P_EXT:RPROCH_STRIP_GUID`）
- **初始化流程**：
  1. 调用 `reaper.TrackFX_AddByName(tr, "Container", false, -1000)` 在顶层最前端（index 0）创建容器。
  2. 将容器重命名为 `◆ CHANNEL STRIP ◆`（使用 `TrackFX_SetNamedConfigParm(tr, 0, "renamed_name", "◆ CHANNEL STRIP ◆")`）。
  3. 读取 `guid = reaper.TrackFX_GetFXGUID(tr, 0)`。
  4. 调用 `reaper.GetSetMediaTrackInfo_String(tr, "P_EXT:REAPCH_STRIP_GUID", guid, true)` 持久化绑定至该轨道。
- **查询流程**：遍历顶层 `0 .. TrackFX_GetCount(tr) - 1`，比对 `TrackFX_GetFXGUID(tr, i) == saved_guid`。
- **删空容错**：若用户在原生窗口中手动删除了该容器，导致 `saved_guid` 无法匹配任何顶层 FX，`core.lua` 必须优雅降级为“未初始化状态”，不可报错或误绑定其他插件。

### 5.2 轮询与性能优化
- 主循环中使用 `reaper.GetProjectStateChangeCount(0)` 叠加当前选中轨道指针（`reaper.GetSelectedTrack(0, 0)`）做变化检测；仅在工程状态或选中轨道变更时重新扫描 FX 列表并刷新视图模型，空转帧零扫描开销。

### 5.3 REAPER 7.06+ FX Container 编址与操作规范
- **读取容器子项**：
  - 子项总数：`local ok, cnt = reaper.TrackFX_GetNamedConfigParm(tr, container_idx, "container_count")`
  - 遍历获取第 `i` 个子项（`0 <= i < tonumber(cnt)`）的完整编址 ID：
    ```lua
    local ok, id_str = reaper.TrackFX_GetNamedConfigParm(tr, container_idx, "container_item." .. i)
    local fx_id = tonumber(id_str)
    ```
  - 该 `fx_id` 可直接传入 `TrackFX_GetFXName`、`TrackFX_GetEnabled`、`TrackFX_SetEnabled`、`TrackFX_Show`、`TrackFX_Delete`、`TrackFX_GetParam`（如 Wet 参数）等标准 API。
- **构造目标容器内位置编码（用于移入或容器内排序）**：
  - 顶层容器索引与目标子项索引在公式中**均为 1-based**：
    ```lua
    -- container_idx_0based: 容器当前在顶层的 0-based 索引
    -- child_pos_0based:     目标在容器内的 0-based 位置（追加至末尾时等于当前 container_count）
    -- parent_fx_count:      执行移动当下实时的 reaper.TrackFX_GetCount(tr)
    local encoded_idx = 0x2000000
      + (child_pos_0based + 1) * (parent_fx_count + 1)
      + (container_idx_0based + 1)
    ```
- **向 0 号位容器添加插件的标准步骤**：
  1. 先添加至轨道顶层末尾：`local new_idx = reaper.TrackFX_AddByName(tr, fx_ident, false, -1)`；
  2. 重新获取实时 `parent_fx_count = reaper.TrackFX_GetCount(tr)` 与当前 `container_count`；
  3. 用上述公式计算容器末尾的 `encoded_idx`；
  4. 调用 `reaper.TrackFX_CopyToTrack(tr, new_idx, tr, encoded_idx, true)` 移入容器；
  5. 多步操作统一包裹在 `reaper.Undo_BeginBlock()` 与 `reaper.Undo_EndBlock("ReaPCh: ...", -1)` 中，保证 Ctrl+Z 一步撤销干净。

### 5.4 ReaImGui 加载与环境兜底
- 启动前检查 `reaper.ImGui_GetBuiltinPath` 是否存在；缺失时用 `reaper.MB` 弹窗提示通过 ReaPack 安装 ReaImGui 并安全退出。
- 加载垫片前必须先核对本地 `docs/imgui.lua` 支持的最新版本号，并按其导出方式初始化：
  ```lua
  package.path = reaper.ImGui_GetBuiltinPath() .. '/?.lua;' .. package.path
  local ImGui = require 'imgui' '<以 docs/imgui.lua 为准>'
  ```

### 5.5 `tests/run.lua` 必测边界用例
`core.lua` 的单元测试必须覆盖以下场景：
1. 无选中轨道 / 空轨道（无任何 FX）。
2. 有普通 FX 但尚未初始化 Strip（上半区为空状态，下半区正常编号 `1..N`）。
3. 初始化 Strip 并连续添加 3 个插件，校验容器编址计算与子项平铺顺序。
4. **MCP 手滑偏离**：容器被移至顶层 `index 2`，校验 GUID 仍准确识别上半区、不误认 `index 0` 的普通插件、正确上报偏离状态，且执行一键归位后恢复至 `index 0`。
5. **手动删容器容错**：在底层删除容器但保留轨道 `P_EXT` 旧 GUID 时，安全回退至未初始化状态。
6. **下半区边界拦截**：下半区拖拽排序或删除时，严禁越界影响 0 号位容器；容器位于非 0 位置时，下半区索引映射依然准确无误。

---

## 6. 版本路线图（Milestones）

### `v0.1.0` — 核心骨架与朴素双区 MVP
- 完成 `src/core.lua` 全部核心逻辑与 `tests/mock_reaper.lua`、`tests/run.lua` 单元测试（100% 通过）。
- 完成 `src/main.lua`、`src/ui.lua`（最朴素 ImGui 默认布局，暂不做视觉精修）：
  - 左侧可停靠窗口、自动跟随选中轨道；
  - 上半区初始化按钮、容器内插件平铺展示、整区总 Bypass、单行 Bypass、点击切换悬浮窗；
  - 下半区隐藏容器并按 `1..N` 编号展示、单行 Bypass、点击切换悬浮窗；
  - 偏离检测提示条与一键归位、右上角 `⚙` 设置菜单基础骨架。

### `v0.2.0` — 完整操作闭环
- 双区独立 `+` 添加插件弹窗：通过 REAPER 7 原生 `reaper.EnumInstalledFX(i)` 缓存并支持关键词即时搜索添加任意第三方 VST/CLAP/JSFX。
- 双区各自内部拖拽排序（带严格边界隔离）与右键/快捷移除。
- 单行轻量级 Wet/Dry 干湿比调节（操作 REAPER 原生 Wet 参数）。
- 按需触发 UI 建构门禁，完成 `src/theme.lua` 视觉体系定型与可选宿主配色开关。

### `v0.3.0` — Strip 预设管理与打磨
- 0 号位 Channel Strip 预设的一键保存与加载（复用 REAPER 原生 `.RfxChain` 或容器预设机制，方便一键套用鼓组/钢琴/贝斯常用模拟条）。
- 完善 `ExtState` 配置持久化、空态引导、边缘异常容错与完整 `README.md` 文档。

### `v0.4.0+` — 远期单轨 Inspector 混音扩展规划（优先级排在双区 FX 核心路线之后）
在双区 FX 核心体验与预设体系稳定后，逐步演进为完整的左侧单轨 Channel Inspector（设计备忘）：
1. **单轨混音核心组件（高优先级远期项）**：
   - **顶部录音与高频通道开关**：录音预备（`R` / Record Arm）、监听模式（`Mon`）、静音（`M`）、独奏（`S`）、反相（`Ø` / Phase Invert）。
   - **发送槽列表（`Sends`）**：展示当前轨道的硬件/轨道发送列表，支持快速调节发送量、静音与点击跳转目标轨道。
   - **底部声像/立体声宽度与推子区**：`Pan / Width`（UI 精修阶段优先采用经典圆弧旋钮 `ImDrawList` 绘制，而非普通水平拉条）+ 通道音量推子（Fader）+ 可选实时 L/R 峰值/RMS 电平表。
2. **底部 `In / MIDI / Out` 路由摘要（中低优先级远期项）**：
   - 不在窄侧边栏内重造复杂的 REAPER 原生路由矩阵；仅做**轻量两行文字状态摘要展示**（如当前输入源 Input / MIDI 通道与 Master/Parent Send 状态）+ **点击直接呼出 REAPER 原生 I/O 路由窗口**。
3. **顶部 Pre-FX Gain 输入增益旋钮（低优先级 Opt-in 可选项）**：
   - 不强制默认内置或常驻占用 FX 槽位；作为设置中的低优先级可选方案（Opt-in），仅在用户显式开启该轨 Pre-FX Gain 时，按需调用 REAPER 原厂自带的 `JS: Volume Adjustment` 并联动其 `Adjustment (dB)` 参数。