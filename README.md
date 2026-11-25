# Reaper ProChannel (`ReaPCh`)

[简体中文](#简体中文) | [日本語](#日本語) | [English](#english)

---

## 简体中文

面向 **REAPER 7** 的轻量级左侧可停靠双区 FX Inspector（Lua ReaScript / ReaImGui），选中任意轨道即自动同步该轨道的插件链视图。

### 环境要求

- **REAPER** `7.06+`
- **ReaImGui** `0.9+`（通过 ReaPack 安装）

### 安装与停靠

1. 在 REAPER 中按 `?` 打开 **Actions**。
2. 点击 **New Action... → Load ReaScript...**，加载 `src/main.lua`。
3. 运行该 Action 打开面板。

**停靠至左侧 Docker**：点击面板右上角 `⚙` → **一键停靠至 REAPER Docker**（若 Docker 不在左侧，右键 Docker 标签栏空白处 → `Attached Docker position: Left`），或直接拖动标题栏至主窗口左边缘蓝框（若开启了 ReaImGui 的 `Dock only when holding Shift`，拖动时按住 `Shift`）。

### 核心功能

- **双区插件视图**：上半区为基于 REAPER 7 原生 FX Container 的 **0 号位 Channel Strip**（按需初始化，平铺展开内部插件并支持整区总 Bypass）；下半区为常规 FX 槽（自动隐藏 Strip 容器并按 `1..N` 编号）。
- **单行快捷操控**：支持单行 Bypass 指示灯、点击插件名开关原生悬浮窗、单行 MIX 干湿比圆弧旋钮（上下拖拽调节、`Shift` 微调、双击重置 `100%`）、快捷移除，以及区内/跨区双向拖拽排序。
- **分组插件搜索**：双区独立 `+ 添加` 弹窗，默认过滤乐器插件，支持多关键词检索、按分类 / REAPER 文件夹 / 厂商 / 格式切换及右键自定义分组。
- **界面与主题**：默认 Studio Dark 深色主题，可在右上角 `⚙` 开启实验性跟随 REAPER 宿主主题配色（兼容浅色与深色皮肤），并支持 Strip 偏离 0 号位检测与一键归位。

### 版本记录

- **`v0.2.1`**（UI 精修）
  - **新增**：宿主浅色/彩色皮肤 HSL 色相保持与全灰度 WCAG 对比度兜底、固定吸顶轨道栏、硬件胶囊总 Bypass 开关、UTF-8 安全截断与窄 Split Dock 紧凑布局。
  - **修复**：中灰/浅灰及位图主题配色异常、窄窗横滚溢出与按钮行距漂移、拖拽默认黄框/遮挡与取消误开窗、MIX 旋钮微抖误写 Undo 与跨行高亮穿透。
- **`v0.2.0`**（核心操作闭环）
  - **新增**：双区独立 `+ 添加` 分组搜索弹窗（默认隐藏乐器、支持 REAPER 文件夹 / A–Z 分类 / 自定义分组）、单行 MIX 圆弧旋钮、区内/跨区双向拖拽排序、Studio Dark 与实验性跟随宿主主题。
  - **修复**：运行中启用 DX 插件无法刷新显示、4 个 `DXi:` 音频效果器被误当乐器隐藏、Wet/Dry 拖拽拆分多步 Undo，以及弹窗 ID 作用域异常。
- **`v0.1.0`**（基础版本）
  - **新增**：0 号位 `Channel Strip` 容器持久识别与按需初始化、常规 FX 槽 `1..N` 映射、双区 Bypass 与插件悬浮窗切换、MCP 偏离检测与一键/自动归位、ReaImGui 可停靠面板与一键停靠 Docker。

---

## 日本語

**REAPER 7** 向けの軽量・左側ドッキング対応 2 ゾーン FX インスペクター（Lua ReaScript / ReaImGui）です。トラックを選択すると、そのトラックの FX チェーン表示が自動同期されます。

### 動作環境

- **REAPER** `7.06+`
- **ReaImGui** `0.9+`（ReaPack からインストール）

### インストールとドッキング

1. REAPER で `?` キーを押して **Actions** を開きます。
2. **New Action... → Load ReaScript...** から `src/main.lua` を読み込みます。
3. 登録された Action を実行してパネルを開きます。

**左側 Docker へのドッキング**：パネル右上の `⚙` → **一键停靠至 REAPER Docker**（REAPER Docker へワンクリックドッキング。Docker が左側にない場合は、Docker タブバーの余白を右クリック → `Attached Docker position: Left`）を実行するか、タイトルバーをメインウィンドウ左端の青いガイド枠へドラッグします（ReaImGui の `Dock only when holding Shift` が有効な場合は `Shift` を押しながらドラッグ）。

### 主な機能

- **2 ゾーン FX ビュー**：上部は REAPER 7 ネイティブ FX Container を使った **スロット 0 Channel Strip**（必要時に初期化、内部プラグインをフラット展開、ゾーン一括 Bypass 対応）。下部は通常 FX スロット（Strip コンテナを非表示にし `1..N` で採番）。
- **行単位のクイック操作**：Bypass LED、プラグイン名クリックでのフローティングウィンドウ開閉、MIX（Wet/Dry）ロータリーノブ（上下ドラッグ調整、`Shift` で微調整、ダブルクリックで `100%` リセット）、ワンクリック削除、ゾーン内／ゾーン間ドラッグ＆ドロップ並べ替えに対応。
- **グループ対応 FX 検索**：各ゾーン専用の `+` 追加ポップアップを搭載。デフォルトでインストゥルメントを除外し、複数キーワード検索、カテゴリ／REAPER フォルダ／開発元／フォーマット切替、右クリックによるカスタムグループ管理が可能。
- **UI とテーマ**：標準の Studio Dark テーマに加え、右上の `⚙` から実験的な REAPER ホストテーマ連動（ライト／ダーク両対応）を切替可能。Strip のスロット 0 位置ずれ検出とワンクリック復帰も備えています。

### 更新履歴

- **`v0.2.1`**（UI ポリッシュ）
  - **追加**：ライト／カラー系ホストテーマ向け HSL 色相保持と全グレースケール WCAG コントラスト保証、上部固定トラックバー、ハードウェア風カプセル一括 Bypass、UTF-8 安全省略表示、狭幅 Split Dock 向けコンパクトレイアウト。
  - **修正**：中間グレー・ライトグレーやビットマップ系テーマでの配色崩れ、狭幅時の横スクロール溢れ・ボタン行間ずれ、ドラッグ時のデフォルト黄枠／重なり描画やキャンセル時誤オープン、MIX ノブの微ブレ Undo 記録および他行ホバー貫通。
- **`v0.2.0`**（コア操作ループ）
  - **追加**：ゾーン別 `+` グループ検索ポップアップ（インストゥルメント既定非表示、REAPER フォルダ／A–Z カテゴリ／カスタムグループ対応）、行内 MIX ロータリーノブ、ゾーン内／ゾーン間双方向ドラッグ移動、Studio Dark および実験的ホストテーマ追従。
  - **修正**：実行中に有効化した DX プラグインが一覧へ反映されない問題、`DXi:` オーディオエフェクト 4 種が楽器として誤除外される問題、Wet/Dry ドラッグ時の Undo 分割、ポップアップの ID スコープ不具合。
- **`v0.1.0`**（初期リリース）
  - **追加**：スロット 0 `Channel Strip` コンテナの永続識別とオンデマンド初期化、通常 FX スロット `1..N` マッピング、両ゾーンの Bypass およびプラグインウィンドウ開閉、MCP 位置ずれ検出とワンクリック／自動復帰、ReaImGui ドッキングパネルおよびワンクリック Docker ドッキング。

---

## English

A lightweight, left-dockable dual-zone FX Inspector for **REAPER 7** (Lua ReaScript / ReaImGui) that automatically follows the currently selected track.

### Requirements

- **REAPER** `7.06+`
- **ReaImGui** `0.9+` (installed via ReaPack)

### Installation & Docking

1. Press `?` in REAPER to open the **Actions** list.
2. Click **New Action... → Load ReaScript...** and load `src/main.lua`.
3. Run the action to open the panel.

**Dock to the Left Docker**: Click `⚙` in the top-right corner → **一键停靠至 REAPER Docker** (Dock to REAPER Docker; if the Docker is not on the left, right-click the empty area of the Docker tab bar → `Attached Docker position: Left`), or drag the title bar onto the blue docking guide at the left edge of the main window (hold `Shift` if ReaImGui's `Dock only when holding Shift` option is enabled).

### Key Features

- **Dual-Zone FX View**: Upper zone hosts a **Slot 0 Channel Strip** backed by a native REAPER 7 FX Container (initialized on demand, flattened child list, master zone bypass); lower zone lists regular FX slots numbered `1..N` with the Strip container hidden.
- **Per-Row Controls**: Hardware-style bypass LED, click FX name to toggle its floating window, per-row MIX (Wet/Dry) arc knob (vertical drag, `Shift` fine tune, double-click to reset to `100%`), quick remove, and bidirectional intra-/cross-zone drag-and-drop reordering.
- **Grouped FX Search**: Dedicated `+` browser popup per zone with instruments hidden by default, multi-keyword search, view switching by Category / REAPER Folders / Developer / Format, and right-click custom groups.
- **UI & Theming**: Built-in Studio Dark theme plus an experimental REAPER host-theme sync option in `⚙` (supports both light and dark skins), alongside slot 0 displacement detection and one-click snap-back.

### Changelog

- **`v0.2.1`** (UI Polish)
  - **Added**: HSL hue-preserving accent adaptation and full-grayscale WCAG contrast safeguards for light/colorful host themes, sticky top track bar, hardware capsule master bypass, UTF-8-safe ellipsis truncation, and compact layout for narrow Split Docks.
  - **Fixed**: Color distortion on mid-/light-gray and bitmap themes, narrow-window horizontal overflow and button baseline drift, default yellow DnD rectangle / Z-order clipping / accidental window open on cancelled drag, and MIX knob micro-jitter Undo spam & cross-row hover bleed.
- **`v0.2.0`** (Core Workflow)
  - **Added**: Per-zone grouped `+` FX browser popup (instruments hidden by default, REAPER folders / A–Z categories / custom groups), per-row MIX arc knob, bidirectional intra-/cross-zone drag-and-drop, Studio Dark theme, and experimental host-theme sync.
  - **Fixed**: Newly enabled DX plugins missing on runtime refresh, 4 `DXi:` audio effects misclassified as instruments, multi-step Undo spam during Wet/Dry drags, and popup ID scoping issues.
- **`v0.1.0`** (Initial MVP)
  - **Added**: Persistent Slot 0 `Channel Strip` container tracking and on-demand initialization, regular FX slot `1..N` mapping, dual-zone bypass and floating FX window toggle, MCP displacement detection with one-click/auto snap-back, and dockable ReaImGui panel with one-click Docker docking.
