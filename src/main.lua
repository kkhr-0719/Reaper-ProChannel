-- src/main.lua
-- Reaper ProChannel (ReaPCh) v0.1.0 — 入口脚本
-- 职责：ReaImGui 环境检测、上下文创建（启用 Docking）、状态变化防抖轮询与 defer 主循环。

if not reaper then
  error("src/main.lua 必须在 REAPER ReaScript 环境中运行。")
end

-- 1. ReaImGui 环境兜底检测
if type(reaper.ImGui_GetBuiltinPath) ~= "function" then
  reaper.MB(
    "未检测到 ReaImGui 扩展。\n\n请先通过 ReaPack 搜索并安装：\n'ReaImGui: ReaScript binding for Dear ImGui' (需 v0.9 / v0.10+)\n安装后重启 REAPER 再运行本脚本。",
    "Reaper ProChannel — 缺少依赖",
    0
  )
  return
end

-- 2. 配置模块加载路径（本机 ReaImGui 内置垫片路径 + 当前脚本所在 src/ 目录）
local script_source = debug.getinfo(1, "S").source or ""
local src_dir = script_source:match("@?(.*[\\/])") or "./"

package.path = table.concat({
  reaper.ImGui_GetBuiltinPath() .. "/?.lua",
  src_dir .. "?.lua",
  package.path,
}, ";")

local ok_shim, imgui_loader = pcall(require, "imgui")
if not ok_shim or type(imgui_loader) ~= "function" then
  reaper.MB(
    "无法加载 ReaImGui 垫片 (imgui.lua)。\n请通过 ReaPack 检查并重新安装 ReaImGui。",
    "Reaper ProChannel — 初始化失败",
    0
  )
  return
end

-- 优先按本机实装的 ReaImGui 0.10 垫片初始化，向下兼容 0.9
local ok_api, ImGui = pcall(imgui_loader, "0.10")
if not ok_api or not ImGui then
  ok_api, ImGui = pcall(imgui_loader, "0.9")
end
if not ok_api or not ImGui then
  reaper.MB(
    "当前 ReaImGui 版本不支持 0.10 或 0.9 API 垫片。\n请通过 ReaPack 将 ReaImGui 更新至最新版本。",
    "Reaper ProChannel — 版本不兼容",
    0
  )
  return
end

local core = require("core")
local ui = require("ui")

-- 3. 创建支持停靠 (Docking) 的 ReaImGui 上下文
local docking_flag = ImGui.ConfigFlags_DockingEnable
if type(docking_flag) == "function" then
  docking_flag = docking_flag()
end
local ctx = ImGui.CreateContext("Reaper ProChannel", docking_flag or 0)

-- 4. 状态防抖缓存与 defer 主循环
local settings = core.load_settings()
local last_state_cnt = -1
local last_track_ptr = nil
local force_refresh = true
local cached_vm = core.build_view_model(nil, settings)

local function mark_dirty()
  force_refresh = true
end

local function loop()
  local cur_state_cnt = reaper.GetProjectStateChangeCount(0)
  local cur_track_ptr = reaper.GetSelectedTrack(0, 0)

  -- 仅在工程状态计数、选中轨道变更或界面触发写操作时重新扫描 FX 列表，空转帧零扫描开销
  if force_refresh or cur_state_cnt ~= last_state_cnt or cur_track_ptr ~= last_track_ptr then
    cached_vm = core.build_view_model(cur_track_ptr, settings)
    last_state_cnt = reaper.GetProjectStateChangeCount(0)
    last_track_ptr = cur_track_ptr
    force_refresh = false
  end

  local open = ui.draw(ctx, ImGui, cached_vm, settings, mark_dirty)
  if open then
    reaper.defer(loop)
  end
end

reaper.defer(loop)
