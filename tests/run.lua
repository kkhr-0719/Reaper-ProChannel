-- tests/run.lua
-- Reaper ProChannel (ReaPCh) — 纯 Lua 单元测试入口
-- 运行方式：
--   1. 命令行：lua tests/run.lua
--   2. REAPER 宿主内：Actions -> ReaScript: Run... 选择 tests/run.lua（自动隔离真实宿主环境并输出至 ReaScript 控制台）

local host_reaper = _G.reaper

local script_source = debug.getinfo(1, "S").source or ""
local tests_dir = script_source:match("@?(.*[\\/])") or "./"
local root_dir = tests_dir:gsub("tests[\\/]?$", "")
if root_dir == "" then
  root_dir = "./"
end

package.path = table.concat({
  root_dir .. "src/?.lua",
  root_dir .. "tests/?.lua",
  "./src/?.lua",
  "./tests/?.lua",
  package.path,
}, ";")

local mock_reaper = require("mock_reaper")
local core = require("core")

local output_lines = {}
local function log_line(msg)
  local text = tostring(msg or "")
  output_lines[#output_lines + 1] = text
  print(text)
  if host_reaper and host_reaper.ShowConsoleMsg then
    host_reaper.ShowConsoleMsg(text .. "\n")
  end
end

local total_tests = 0
local passed_tests = 0
local failed_tests = 0

local function assert_eq(actual, expected, label)
  if actual ~= expected then
    error(string.format(
      "%s: expected [%s] (%s), got [%s] (%s)",
      label or "assert_eq failed",
      tostring(expected),
      type(expected),
      tostring(actual),
      type(actual)
    ), 2)
  end
end

local function assert_true(val, label)
  if not val then
    error(string.format("%s: expected truthy value, got [%s]", label or "assert_true failed", tostring(val)), 2)
  end
end

local function assert_false(val, label)
  if val then
    error(string.format("%s: expected falsy value, got [%s]", label or "assert_false failed", tostring(val)), 2)
  end
end

local function run_test(name, fn)
  total_tests = total_tests + 1
  local clean_name = tostring(name or ""):gsub("^%d+%.%s*", "")
  local r = mock_reaper.new()
  core.set_reaper(r)
  _G.reaper = r

  local ok, err = xpcall(function()
    fn(r)
  end, debug.traceback)

  if ok then
    passed_tests = passed_tests + 1
    log_line(string.format("[PASS] %d. %s", total_tests, clean_name))
  else
    failed_tests = failed_tests + 1
    log_line(string.format("[FAIL] %d. %s\n%s", total_tests, clean_name, tostring(err)))
  end
end

log_line("============================================================")
log_line("Reaper ProChannel (ReaPCh) v" .. tostring(core.VERSION) .. " Unit Test Suite")
log_line("============================================================")

--------------------------------------------------------------------------------
-- 用例 1：无选中轨道 / 空轨道（无任何 FX）
--------------------------------------------------------------------------------
run_test("无选中轨道与空轨道（无任何 FX）及空指针防御", function(r)
  -- 1.1 无选中轨道
  local vm_nil = core.build_view_model(nil)
  assert_false(vm_nil.has_track, "nil track has_track")
  assert_false(vm_nil.strip.initialized, "nil track strip.initialized")
  assert_eq(#vm_nil.strip.children, 0, "nil track strip.children count")
  assert_eq(#vm_nil.normal_fx, 0, "nil track normal_fx count")

  -- 无轨道时调用各操作函数应安全返回 false，不抛异常
  assert_false(core.init_strip_container(nil), "init_strip_container(nil)")
  assert_false(core.add_fx_to_strip(nil, "VST3: ReaEQ"), "add_fx_to_strip(nil)")
  assert_false(core.snap_strip_to_top(nil), "snap_strip_to_top(nil)")
  assert_false(core.move_normal_fx(nil, 1, 2), "move_normal_fx(nil)")
  assert_false(core.delete_normal_fx(nil, 1), "delete_normal_fx(nil)")

  -- 1.2 选中空轨道（0 个 FX）
  local tr = r.mock_add_track("Lead Vocal")
  local vm_empty = core.build_view_model(tr)
  assert_true(vm_empty.has_track, "empty track has_track")
  assert_eq(vm_empty.track_name, "Lead Vocal", "empty track name")
  assert_false(vm_empty.strip.initialized, "empty track strip.initialized")
  assert_false(vm_empty.strip.is_displaced, "empty track strip.is_displaced")
  assert_eq(#vm_empty.strip.children, 0, "empty track strip.children count")
  assert_eq(#vm_empty.normal_fx, 0, "empty track normal_fx count")
end)

--------------------------------------------------------------------------------
-- 用例 2：有普通 FX 但尚未初始化 Strip（上半区为空状态，下半区正常编号 1..N）
--------------------------------------------------------------------------------
run_test("有普通 FX 但尚未初始化 Strip（上半区为空，下半区编号 1..N）", function(r)
  local tr = r.mock_add_track("Acoustic Guitar")
  r.TrackFX_AddByName(tr, "VST3: ReaEQ", false, -1)
  r.TrackFX_AddByName(tr, "VST3: ReaComp", false, -1)
  r.TrackFX_AddByName(tr, "JS: Limiter", false, -1)

  local vm = core.build_view_model(tr)
  assert_true(vm.has_track, "has_track")
  assert_false(vm.strip.initialized, "strip should not be auto-initialized")
  assert_eq(vm.strip.container_index, nil, "strip container_index is nil")
  assert_eq(#vm.strip.children, 0, "strip children empty")

  assert_eq(#vm.normal_fx, 3, "normal_fx count")
  assert_eq(vm.normal_fx[1].visual_slot, 1, "slot 1 visual_slot")
  assert_eq(vm.normal_fx[1].top_index, 0, "slot 1 top_index")
  assert_eq(vm.normal_fx[1].name, "VST3: ReaEQ", "slot 1 name")

  assert_eq(vm.normal_fx[2].visual_slot, 2, "slot 2 visual_slot")
  assert_eq(vm.normal_fx[2].top_index, 1, "slot 2 top_index")
  assert_eq(vm.normal_fx[2].name, "VST3: ReaComp", "slot 2 name")

  assert_eq(vm.normal_fx[3].visual_slot, 3, "slot 3 visual_slot")
  assert_eq(vm.normal_fx[3].top_index, 2, "slot 3 top_index")
  assert_eq(vm.normal_fx[3].name, "JS: Limiter", "slot 3 name")
end)

--------------------------------------------------------------------------------
-- 用例 3：初始化 Strip 并连续添加 3 个插件，校验容器编址计算与子项平铺顺序
--------------------------------------------------------------------------------
run_test("初始化 Strip 并连续添加 3 个插件（校验 0x2000000 编址公式与平铺顺序）", function(r)
  local tr = r.mock_add_track("Drum Bus")
  -- 先放 1 个常规插件，验证初始化 Strip 会精确插入到顶层 index 0
  r.TrackFX_AddByName(tr, "VST3: RoomReverb", false, -1)

  local ok_init, c_idx, c_guid = core.init_strip_container(tr)
  assert_true(ok_init, "init_strip_container ok")
  assert_eq(c_idx, 0, "container created at top-level index 0")
  assert_true(type(c_guid) == "string" and #c_guid > 0, "container GUID non-empty")

  -- 校验 P_EXT 持久化与容器重命名
  local ok_ext, saved_guid = r.GetSetMediaTrackInfo_String(tr, core.TRACK_EXT_KEY, "", false)
  assert_true(ok_ext, "P_EXT saved")
  assert_eq(saved_guid, c_guid, "P_EXT GUID matches container GUID")
  local _, c_name = r.TrackFX_GetFXName(tr, 0, "")
  assert_eq(c_name, "◆ CHANNEL STRIP ◆", "container renamed to ◆ CHANNEL STRIP ◆")

  -- 连续添加 3 个插件进入 0 号位 Strip 容器
  -- 此时顶层已有 2 个 FX（0: Container, 1: RoomReverb）。
  -- 每次 add_fx_to_strip 先在顶层末尾添加临时 FX（此时 parent_fx_count = 3），再移入容器（移入后 parent_fx_count = 2）。
  local ok1, final_id1, move_id1 = core.add_fx_to_strip(tr, "VST3: NevePreamp")
  local ok2, final_id2, move_id2 = core.add_fx_to_strip(tr, "VST3: API550A_EQ")
  local ok3, final_id3, move_id3 = core.add_fx_to_strip(tr, "VST3: SSL_G_Comp")

  assert_true(ok1 and ok2 and ok3, "all 3 strip plugins added")

  -- 严格校验移入时的目标编码公式：0x2000000 + (child_pos_0based + 1) * (3 + 1) + (0 + 1)
  assert_eq(move_id1, 0x2000000 + 1 * 4 + 1, "child 0 move target encoded_idx")
  assert_eq(move_id2, 0x2000000 + 2 * 4 + 1, "child 1 move target encoded_idx")
  assert_eq(move_id3, 0x2000000 + 3 * 4 + 1, "child 2 move target encoded_idx")

  -- 严格校验移入完成后的实时子项 fx_id：0x2000000 + (child_pos_0based + 1) * (2 + 1) + (0 + 1)
  assert_eq(final_id1, 0x2000000 + 1 * 3 + 1, "child 0 final fx_id")
  assert_eq(final_id2, 0x2000000 + 2 * 3 + 1, "child 1 final fx_id")
  assert_eq(final_id3, 0x2000000 + 3 * 3 + 1, "child 2 final fx_id")

  -- 校验视图模型中的平铺顺序与下半区隐藏容器
  local vm = core.build_view_model(tr)
  assert_true(vm.strip.initialized, "strip initialized")
  assert_eq(vm.strip.container_index, 0, "strip at index 0")
  assert_false(vm.strip.is_displaced, "strip not displaced")
  assert_eq(#vm.strip.children, 3, "strip children count == 3")

  assert_eq(vm.strip.children[1].slot, 1, "strip child 1 slot")
  assert_eq(vm.strip.children[1].name, "VST3: NevePreamp", "strip child 1 name")
  assert_eq(vm.strip.children[1].fx_id, final_id1, "strip child 1 fx_id")

  assert_eq(vm.strip.children[2].slot, 2, "strip child 2 slot")
  assert_eq(vm.strip.children[2].name, "VST3: API550A_EQ", "strip child 2 name")
  assert_eq(vm.strip.children[2].fx_id, final_id2, "strip child 2 fx_id")

  assert_eq(vm.strip.children[3].slot, 3, "strip child 3 slot")
  assert_eq(vm.strip.children[3].name, "VST3: SSL_G_Comp", "strip child 3 name")
  assert_eq(vm.strip.children[3].fx_id, final_id3, "strip child 3 fx_id")

  -- 下半区应隐藏 0 号位容器，仅显示 RoomReverb 且视觉编号为 1
  assert_eq(#vm.normal_fx, 1, "normal_fx hides container")
  assert_eq(vm.normal_fx[1].visual_slot, 1, "normal_fx[1] visual_slot == 1")
  assert_eq(vm.normal_fx[1].top_index, 1, "normal_fx[1] top_index == 1")
  assert_eq(vm.normal_fx[1].name, "VST3: RoomReverb", "normal_fx[1] name")
end)

--------------------------------------------------------------------------------
-- 用例 4：MCP 手滑偏离（移至顶层 index 2 -> GUID 识别 -> 不误认 index 0 -> 一键归位与自动归位）
--------------------------------------------------------------------------------
run_test("MCP 手滑偏离检测、防误认 index 0、一键归位与 Auto-Snap", function(r)
  local tr = r.mock_add_track("Bass")
  local _, _, strip_guid = core.init_strip_container(tr)
  core.add_fx_to_strip(tr, "VST3: BassPreamp")
  core.add_fx_to_strip(tr, "VST3: BassComp")

  -- 添加 3 个普通插件（位于顶层 index 1, 2, 3）
  r.TrackFX_AddByName(tr, "VST3: Chorus", false, -1)
  r.TrackFX_AddByName(tr, "VST3: Delay", false, -1)
  r.TrackFX_AddByName(tr, "VST3: Limiter", false, -1)

  -- 模拟用户在原生 MCP 中手滑把 0 号位容器拖到顶层 index 2
  -- 移动后顶层顺序：[0: Chorus, 1: Delay, 2: StripContainer, 3: Limiter]
  r.TrackFX_CopyToTrack(tr, 0, tr, 2, true)

  local vm_displaced = core.build_view_model(tr, { auto_snap_slot0 = false })
  assert_true(vm_displaced.strip.initialized, "displaced strip still recognized by GUID")
  assert_eq(vm_displaced.strip.container_guid, strip_guid, "GUID matches")
  assert_eq(vm_displaced.strip.container_index, 2, "displaced strip detected at top-level index 2")
  assert_true(vm_displaced.strip.is_displaced, "is_displaced flag is true")
  assert_eq(vm_displaced.strip.displaced_pos, 3, "displaced_pos is #3 (1-based)")

  -- 校验上半区子插件在容器偏离至 index 2 时仍能正确编址读取
  assert_eq(#vm_displaced.strip.children, 2, "displaced strip keeps 2 children")
  assert_eq(vm_displaced.strip.children[1].name, "VST3: BassPreamp", "child 1 name when displaced")
  assert_eq(vm_displaced.strip.children[2].name, "VST3: BassComp", "child 2 name when displaced")
  -- 此时 parent_fx_count = 4, container_idx_0based = 2 -> child 0 fx_id = 0x2000000 + 1*5 + 3 = 0x2000008
  assert_eq(vm_displaced.strip.children[1].fx_id, 0x2000000 + 1 * 5 + 3, "child 1 fx_id reflects container at index 2")

  -- 校验绝不误认位于 index 0 的 Chorus，下半区应按 1..3 列出 Chorus, Delay, Limiter
  assert_eq(#vm_displaced.normal_fx, 3, "3 normal FX in lower zone")
  assert_eq(vm_displaced.normal_fx[1].visual_slot, 1, "normal 1 visual_slot")
  assert_eq(vm_displaced.normal_fx[1].top_index, 0, "normal 1 is at top_index 0")
  assert_eq(vm_displaced.normal_fx[1].name, "VST3: Chorus", "normal 1 is Chorus")

  assert_eq(vm_displaced.normal_fx[2].visual_slot, 2, "normal 2 visual_slot")
  assert_eq(vm_displaced.normal_fx[2].top_index, 1, "normal 2 is at top_index 1")
  assert_eq(vm_displaced.normal_fx[2].name, "VST3: Delay", "normal 2 is Delay")

  assert_eq(vm_displaced.normal_fx[3].visual_slot, 3, "normal 3 visual_slot")
  assert_eq(vm_displaced.normal_fx[3].top_index, 3, "normal 3 skips index 2 -> top_index 3")
  assert_eq(vm_displaced.normal_fx[3].name, "VST3: Limiter", "normal 3 is Limiter")

  -- 执行一键归位
  local ok_snap, moved = core.snap_strip_to_top(tr)
  assert_true(ok_snap and moved, "snap_strip_to_top succeeded")

  local vm_snapped = core.build_view_model(tr)
  assert_eq(vm_snapped.strip.container_index, 0, "strip returned to index 0")
  assert_false(vm_snapped.strip.is_displaced, "is_displaced cleared")
  assert_eq(vm_snapped.strip.displaced_pos, nil, "displaced_pos nil")
  assert_eq(#vm_snapped.strip.children, 2, "children intact after snap")
  assert_eq(vm_snapped.normal_fx[1].top_index, 1, "Chorus shifted to top_index 1")
  assert_eq(vm_snapped.normal_fx[2].top_index, 2, "Delay shifted to top_index 2")
  assert_eq(vm_snapped.normal_fx[3].top_index, 3, "Limiter at top_index 3")

  -- 验证开启 Auto-Snap Strip to Slot 0 时自动吸回
  r.TrackFX_CopyToTrack(tr, 0, tr, 2, true)
  local vm_autosnap = core.build_view_model(tr, { auto_snap_slot0 = true })
  assert_true(vm_autosnap.strip.auto_snapped, "auto_snapped triggered")
  assert_eq(vm_autosnap.strip.container_index, 0, "auto-snapped back to index 0")
  assert_false(vm_autosnap.strip.is_displaced, "not displaced after auto-snap")
end)

--------------------------------------------------------------------------------
-- 用例 5：手动删容器容错（保留轨道 P_EXT 旧 GUID 时安全回退至未初始化状态）
--------------------------------------------------------------------------------
run_test("手动删容器容错（旧 P_EXT GUID 残留时优雅降级并可重新初始化）", function(r)
  local tr = r.mock_add_track("Synth Pad")
  local _, _, old_guid = core.init_strip_container(tr)
  core.add_fx_to_strip(tr, "VST3: TapeSat")
  r.TrackFX_AddByName(tr, "VST3: ShimmerVerb", false, -1)

  -- 模拟用户在原生 FX Chain 窗口直接删除了 0 号位容器（但 P_EXT:REAPCH_STRIP_GUID 仍残留旧值）
  r.TrackFX_Delete(tr, 0)

  local ok_ext, residual_guid = r.GetSetMediaTrackInfo_String(tr, core.TRACK_EXT_KEY, "", false)
  assert_true(ok_ext and residual_guid == old_guid, "old GUID still in P_EXT")

  local found_idx, saved_guid, is_stale = core.find_strip_container(tr)
  assert_eq(found_idx, nil, "find_strip_container returns nil index")
  assert_eq(saved_guid, old_guid, "returns residual GUID")
  assert_true(is_stale, "is_stale_guid is true")

  local vm = core.build_view_model(tr)
  assert_false(vm.strip.initialized, "gracefully degrades to uninitialized state")
  assert_true(vm.strip.is_stale_guid, "vm reports is_stale_guid")
  assert_eq(#vm.strip.children, 0, "strip children empty")

  -- 位于 index 0 的 ShimmerVerb 绝不能被误认为 Strip，而应在下半区作为 1 号插件
  assert_eq(#vm.normal_fx, 1, "ShimmerVerb in normal_fx")
  assert_eq(vm.normal_fx[1].visual_slot, 1, "ShimmerVerb is visual_slot 1")
  assert_eq(vm.normal_fx[1].top_index, 0, "ShimmerVerb is top_index 0")
  assert_eq(vm.normal_fx[1].name, "VST3: ShimmerVerb", "ShimmerVerb name intact")

  -- 重新点击初始化 Strip 应能正常新建容器并更新 P_EXT GUID
  local ok_reinit, new_idx, new_guid = core.init_strip_container(tr)
  assert_true(ok_reinit, "re-initialize after manual deletion succeeds")
  assert_eq(new_idx, 0, "new container at index 0")
  assert_true(new_guid ~= old_guid, "new GUID generated and bound")
end)

--------------------------------------------------------------------------------
-- 用例 6：下半区边界拦截（严禁越界影响 0 号位容器；容器位于非 0 位置时映射依然准确）
--------------------------------------------------------------------------------
run_test("下半区拖拽排序与删除边界拦截（含容器位于 0 号位与非 0 号位双场景）", function(r)
  local tr = r.mock_add_track("Master")
  local _, _, strip_guid = core.init_strip_container(tr)
  core.add_fx_to_strip(tr, "VST3: ConsoleIn")
  core.add_fx_to_strip(tr, "VST3: MasterEQ")

  r.TrackFX_AddByName(tr, "VST3: NormA", false, -1)
  r.TrackFX_AddByName(tr, "VST3: NormB", false, -1)
  r.TrackFX_AddByName(tr, "VST3: NormC", false, -1)

  -- 6.1 容器位于 index 0 时，尝试各种越界排序和越界删除
  assert_false(core.move_normal_fx(tr, 0, 1), "reject move from visual_slot 0")
  assert_false(core.move_normal_fx(tr, 1, 0), "reject move to visual_slot 0")
  assert_false(core.move_normal_fx(tr, -1, 2), "reject negative visual_slot")
  assert_false(core.move_normal_fx(tr, 1, 4), "reject visual_slot > N")
  assert_false(core.delete_normal_fx(tr, 0), "reject delete visual_slot 0")
  assert_false(core.delete_normal_fx(tr, -1), "reject delete negative visual_slot")
  assert_false(core.delete_normal_fx(tr, 4), "reject delete visual_slot > N")
  assert_false(core.delete_top_fx_guarded(tr, 0), "reject guarded top_index delete on strip index 0")

  -- 校验 0 号位容器及其子项毫发无损
  local vm1 = core.build_view_model(tr)
  assert_eq(vm1.strip.container_index, 0, "strip still at index 0")
  assert_eq(vm1.strip.container_guid, strip_guid, "strip GUID intact")
  assert_eq(#vm1.strip.children, 2, "strip still has 2 children")

  -- 6.2 容器偏离至顶层 index 2 时（顶层：[0: NormA, 1: NormB, 2: Strip, 3: NormC]）
  r.TrackFX_CopyToTrack(tr, 0, tr, 2, true)
  assert_eq(core.visual_slot_to_top_index(tr, 1), 0, "displaced map slot 1 -> top 0")
  assert_eq(core.visual_slot_to_top_index(tr, 2), 1, "displaced map slot 2 -> top 1")
  assert_eq(core.visual_slot_to_top_index(tr, 3), 3, "displaced map slot 3 -> top 3 (skips 2)")
  assert_eq(core.visual_slot_to_top_index(tr, 0), nil, "displaced map slot 0 -> nil")
  assert_eq(core.visual_slot_to_top_index(tr, 4), nil, "displaced map slot 4 -> nil")

  -- 尝试直接按顶层索引删除偏离在 index 2 的容器，必须被硬拦截
  assert_false(core.delete_top_fx_guarded(tr, 2), "reject guarded delete on displaced strip at index 2")

  -- 在容器位于 index 2 时，对下半区执行合法排序（将 slot 3 [NormC] 移到 slot 2 [NormB] 位置）
  assert_true(core.move_normal_fx(tr, 3, 2), "valid move_normal_fx(3, 2) with displaced strip")
  local vm2 = core.build_view_model(tr)
  assert_true(vm2.strip.initialized, "strip intact after normal FX move")
  assert_eq(#vm2.strip.children, 2, "strip children intact after normal FX move")
  assert_eq(vm2.normal_fx[1].name, "VST3: NormA", "normal slot 1 is NormA")
  assert_eq(vm2.normal_fx[2].name, "VST3: NormC", "normal slot 2 is NormC")
  assert_eq(vm2.normal_fx[3].name, "VST3: NormB", "normal slot 3 is NormB")

  -- 在容器位于非 0 位置时，删除下半区 slot 2 (NormC)
  assert_true(core.delete_normal_fx(tr, 2), "valid delete_normal_fx(2) with displaced strip")
  local vm3 = core.build_view_model(tr)
  assert_true(vm3.strip.initialized, "strip intact after normal FX delete")
  assert_eq(#vm3.strip.children, 2, "strip children intact after normal FX delete")
  assert_eq(#vm3.normal_fx, 2, "2 normal FX remain")
  assert_eq(vm3.normal_fx[1].name, "VST3: NormA", "remaining slot 1 is NormA")
  assert_eq(vm3.normal_fx[2].name, "VST3: NormB", "remaining slot 2 is NormB")

  -- 6.3 下半区插入常规 FX 边界拦截（严禁写入 visual_slot <= 0 或挤占 0 号位容器）
  core.snap_strip_to_top(tr)
  assert_false(core.add_normal_fx(tr, "VST3: BadZero", 0), "reject add_normal_fx at visual_slot 0")
  assert_false(core.add_normal_fx(tr, "VST3: BadNeg", -1), "reject add_normal_fx at negative visual_slot")
  assert_false(core.add_normal_fx(tr, "VST3: BadHigh", 4), "reject add_normal_fx at visual_slot > N + 1")

  -- 插入到下半区 visual_slot 1 时，必须落在 0 号位容器之后 (top_index = 1)，不得把 0 号位容器挤到 index 1
  local ok_ins1, ins1_top = core.add_normal_fx(tr, "VST3: InsertedSlot1", 1)
  assert_true(ok_ins1, "add_normal_fx at visual_slot 1 succeeds")
  assert_eq(ins1_top, 1, "visual_slot 1 inserts at top_index 1 (after strip container)")
  local vm4 = core.build_view_model(tr)
  assert_eq(vm4.strip.container_index, 0, "strip container remains at top_index 0 after visual_slot 1 insert")
  assert_eq(#vm4.normal_fx, 3, "3 normal FX after insert")
  assert_eq(vm4.normal_fx[1].name, "VST3: InsertedSlot1", "normal slot 1 is InsertedSlot1")
  assert_eq(vm4.normal_fx[2].name, "VST3: NormA", "normal slot 2 is NormA")
  assert_eq(vm4.normal_fx[3].name, "VST3: NormB", "normal slot 3 is NormB")
end)

--------------------------------------------------------------------------------
-- 用例 7：上半区自动建容器置入、容器内排序/移除、Bypass/弹窗切换与 ExtState 配置持久化
--------------------------------------------------------------------------------
run_test("上半区未初始化直接添加插件（含失败回滚）、区内排序/移除、Bypass/悬浮窗与 ExtState", function(r)
  local tr = r.mock_add_track("Keys")

  -- 未初始化轨道添加不存在的插件时，必须原子回滚，不得残留空 Container 或污染 P_EXT
  assert_false(core.add_fx_to_strip(tr, "__MISSING__: NonExistentFX"), "add_fx_to_strip fails on missing FX")
  assert_eq(r.TrackFX_GetCount(tr), 0, "no orphan container left after failed add_fx_to_strip")
  assert_eq(core.find_strip_container(tr), nil, "strip remains uninitialized after failed add_fx_to_strip")

  -- 未初始化时直接调用 add_fx_to_strip 应自动创建 0 号位容器并置入插件
  local ok_add = core.add_fx_to_strip(tr, "VST3: RhodesPre")
  assert_true(ok_add, "add_fx_to_strip auto-creates strip container")
  core.add_fx_to_strip(tr, "VST3: Phaser")
  core.add_fx_to_strip(tr, "VST3: TapeComp")

  local vm = core.build_view_model(tr)
  assert_true(vm.strip.initialized, "strip auto-initialized")
  assert_eq(#vm.strip.children, 3, "3 children in strip")

  -- 容器内排序：把第 3 个 (TapeComp) 移到第 2 个位置
  assert_false(core.move_strip_fx(tr, 0, 1), "reject strip move from slot 0")
  assert_false(core.move_strip_fx(tr, 1, 4), "reject strip move to slot 4")
  assert_true(core.move_strip_fx(tr, 3, 2), "move strip slot 3 -> 2")

  vm = core.build_view_model(tr)
  assert_eq(vm.strip.children[1].name, "VST3: RhodesPre", "strip slot 1")
  assert_eq(vm.strip.children[2].name, "VST3: TapeComp", "strip slot 2 after reorder")
  assert_eq(vm.strip.children[3].name, "VST3: Phaser", "strip slot 3 after reorder")

  -- 容器内单行 Bypass 与悬浮窗切换
  local child2_id = vm.strip.children[2].fx_id
  assert_true(vm.strip.children[2].enabled, "child 2 initially enabled")
  core.set_fx_enabled(tr, child2_id, false)
  assert_false(r.TrackFX_GetEnabled(tr, child2_id), "child 2 bypassed")

  assert_false(vm.strip.children[2].is_open, "child 2 window initially closed")
  core.toggle_fx_floating_window(tr, child2_id)
  assert_true(r.TrackFX_GetOpen(tr, child2_id), "child 2 window opened")
  core.toggle_fx_floating_window(tr, child2_id)
  assert_false(r.TrackFX_GetOpen(tr, child2_id), "child 2 window closed")

  -- 越界 fx_id 防御
  assert_false(core.set_fx_enabled(tr, 99, false), "reject out-of-bounds top-level fx_id on set_fx_enabled")
  assert_false(core.toggle_fx_floating_window(tr, 99), "reject out-of-bounds top-level fx_id on toggle_fx_floating_window")
  local oob_child_id = core.encode_container_item_index(0, 9, r.TrackFX_GetCount(tr))
  assert_false(core.set_fx_enabled(tr, oob_child_id, false), "reject out-of-bounds container child fx_id")
  assert_false(core.toggle_fx_floating_window(tr, oob_child_id), "reject out-of-bounds container child fx_id on window toggle")

  -- 整区总 Bypass
  core.set_strip_enabled(tr, false)
  assert_false(r.TrackFX_GetEnabled(tr, 0), "entire strip container bypassed")
  core.set_strip_enabled(tr, nil) -- toggle back
  assert_true(r.TrackFX_GetEnabled(tr, 0), "entire strip container re-enabled")

  -- 容器内移除子插件
  assert_false(core.remove_strip_fx(tr, 0), "reject remove strip slot 0")
  assert_false(core.remove_strip_fx(tr, 4), "reject remove strip slot 4")
  assert_true(core.remove_strip_fx(tr, 2), "remove strip slot 2 (TapeComp)")
  vm = core.build_view_model(tr)
  assert_eq(#vm.strip.children, 2, "2 children left in strip")
  assert_eq(vm.strip.children[1].name, "VST3: RhodesPre", "remaining strip slot 1")
  assert_eq(vm.strip.children[2].name, "VST3: Phaser", "remaining strip slot 2")

  -- ExtState 配置读写（含旧版 RPROCH 与新版 REAPCH 兼容校验）
  local s0 = core.load_settings()
  assert_false(s0.auto_snap_slot0, "default auto_snap_slot0 is false")
  assert_false(s0.follow_host_theme, "default follow_host_theme is false")

  r.SetExtState("RPROCH", "auto_snap_slot0", "1", true)
  local s_legacy = core.load_settings()
  assert_true(s_legacy.auto_snap_slot0, "legacy RPROCH ExtState fallback read works")

  core.save_setting("auto_snap_slot0", true)
  core.save_setting("follow_host_theme", true)
  assert_eq(r.GetExtState("REAPCH", "auto_snap_slot0"), "1", "saved to primary REAPCH ExtState")
  local s1 = core.load_settings()
  assert_true(s1.auto_snap_slot0, "saved auto_snap_slot0 is true")
  assert_true(s1.follow_host_theme, "saved follow_host_theme is true")

  -- 旧版 P_EXT:RPROCH_STRIP_GUID 兼容认亲校验
  local tr_legacy = r.mock_add_track("Legacy Track")
  local c_idx = r.TrackFX_AddByName(tr_legacy, "Container", false, -1000)
  local c_guid = r.TrackFX_GetFXGUID(tr_legacy, c_idx)
  r.GetSetMediaTrackInfo_String(tr_legacy, "P_EXT:RPROCH_STRIP_GUID", c_guid, true)
  local found_legacy_idx, found_legacy_guid = core.find_strip_container(tr_legacy)
  assert_eq(found_legacy_idx, 0, "legacy P_EXT:RPROCH_STRIP_GUID recognized")
  assert_eq(found_legacy_guid, c_guid, "legacy P_EXT GUID matches")
end)

--------------------------------------------------------------------------------
-- 用例 8 (v0.2.0)：EnumInstalledFX 插件枚举缓存、多关键词搜索过滤与特殊字符防御
--------------------------------------------------------------------------------
run_test("v0.2.0 EnumInstalledFX 插件枚举缓存、强制刷新、多关键词过滤与特殊字符防御", function(r)
  -- 8.1 默认枚举应自动过滤掉裸 Container，仅保留 7 个真实插件
  local all_fx = core.get_installed_fx()
  assert_eq(#all_fx, 7, "installed_fx excludes bare Container (7 plugins)")
  assert_eq(all_fx[1].name, "VST3: ReaEQ (Cockos)", "first cached plugin name")
  assert_eq(all_fx[1].format, "VST3", "first cached plugin format parsed")

  -- 8.2 缓存命中与 force_refresh 强制刷新校验
  r.mock_set_installed_fx({
    { name = "Container", ident = "Container" },
    { name = "", ident = "" },
    { name = "VST3: Pro-Q 3 (FabFilter)", ident = "FabFilter Pro-Q 3.vst3" },
    { name = "CLAP: Vital+ [100%] (Matt Tytel)", ident = "vital.clap" },
    { name = "JS: Volume Adjustment", ident = "utility/volume" },
  })
  -- 未传 force_refresh 时应返回旧缓存 (7 项)
  assert_eq(#core.get_installed_fx(false), 7, "returns cached list without force_refresh")
  -- 传入 force_refresh = true 时应重新扫描并过滤掉 Container 与空项 (剩 3 项)
  local refreshed = core.get_installed_fx(true)
  assert_eq(#refreshed, 3, "force_refresh rescans and filters empty/Container")

  -- 8.3 多关键词大小写不敏感与正则特殊字符（- + [ ] ( ) % .）纯文本安全匹配
  local res_eq, total_eq = core.filter_installed_fx("vst3 pro-q (fabfilter)")
  assert_eq(total_eq, 1, "multi-token query with hyphens and parens matches 1")
  assert_eq(res_eq[1].name, "VST3: Pro-Q 3 (FabFilter)", "matched Pro-Q 3")

  local res_special, total_special = core.filter_installed_fx("vital+ [100%]")
  assert_eq(total_special, 1, "query with +, [, ], % special chars does not throw pattern error")
  assert_eq(res_special[1].format, "CLAP", "matched CLAP Vital+")

  -- 按 ident 内部路径关键词搜索（如 utility/volume）
  local res_ident, total_ident = core.filter_installed_fx("utility/volume")
  assert_eq(total_ident, 1, "query matches plugin ident")
  assert_eq(res_ident[1].name, "JS: Volume Adjustment", "matched JS Volume Adjustment by ident")

  -- 8.4 max_results 截断与 total_matched 统计
  local res_lim, total_lim = core.filter_installed_fx("", 2)
  assert_eq(total_lim, 3, "empty query total_matched == 3")
  assert_eq(#res_lim, 2, "max_results == 2 caps returned list length to 2")

  -- 8.5 搜索结果直接添加至上半区与下半区闭环
  local tr = r.mock_add_track("Search & Add Track")
  assert_true(core.add_fx_to_strip(tr, res_eq[1].add_name), "add searched plugin to strip")
  assert_true(core.add_normal_fx(tr, res_special[1].add_name), "add searched plugin to normal zone")
  local vm = core.build_view_model(tr)
  assert_eq(#vm.strip.children, 1, "1 plugin in strip from search")
  assert_eq(vm.strip.children[1].name, "VST3: Pro-Q 3 (FabFilter)", "strip plugin name from search")
  assert_eq(#vm.normal_fx, 1, "1 plugin in normal zone from search")
  assert_eq(vm.normal_fx[1].name, "CLAP: Vital+ [100%] (Matt Tytel)", "normal plugin name from search")

  -- 8.6 宿主缺失 EnumInstalledFX 时的安全降级
  r.EnumInstalledFX = nil
  core.clear_installed_fx_cache()
  local empty_list, empty_total = core.filter_installed_fx("eq")
  assert_eq(#empty_list, 0, "graceful empty list when EnumInstalledFX is missing")
  assert_eq(empty_total, 0, "graceful 0 total when EnumInstalledFX is missing")
end)

--------------------------------------------------------------------------------
-- 用例 9 (v0.2.0)：单行 Wet/Dry 原生干湿比读写、边界夹紧、偏离保持与 Undo 控制
--------------------------------------------------------------------------------
run_test("v0.2.0 单行 Wet/Dry 原生参数读写（覆盖容器子项、常规槽、夹紧、回退与 Undo 控制）", function(r)
  local tr = r.mock_add_track("Parallel Compression")
  core.add_fx_to_strip(tr, "VST3: API550A")
  core.add_fx_to_strip(tr, "VST3: 1176Comp")
  core.add_normal_fx(tr, "VST3: PlateReverb")

  -- 9.1 默认干湿比为 1.0 (100%)
  local vm = core.build_view_model(tr)
  assert_eq(vm.strip.children[1].wet, 1.0, "strip child 1 default wet == 1.0")
  assert_eq(vm.strip.children[1].wet_percent, 100, "strip child 1 default wet_percent == 100")
  assert_eq(vm.normal_fx[1].wet, 1.0, "normal fx 1 default wet == 1.0")
  assert_eq(vm.normal_fx[1].wet_percent, 100, "normal fx 1 default wet_percent == 100")

  -- 9.2 修改 0 号位容器子项与下半区常规插件的 Wet/Dry
  local child2_id = vm.strip.children[2].fx_id
  local child2_guid = vm.strip.children[2].guid
  local norm1_id = vm.normal_fx[1].fx_id

  local undo_before = #r._state.undo_history
  -- 模拟 UI 连续拖拽过程 (record_undo = false)：实时更新参数但不产生 Undo 记录
  local ok_drag, val_drag = core.set_fx_wet(tr, child2_id, 0.42, false)
  assert_true(ok_drag, "set_fx_wet during drag succeeds")
  assert_eq(val_drag, 0.42, "applied wet == 0.42")
  assert_eq(#r._state.undo_history, undo_before, "record_undo=false does not add undo entry")

  -- 模拟松手提交 (record_undo = true, pre_undo_wet_0_to_1 = 1.0)：先恢复拖拽前基线 1.0 再进入 UndoBlock 写入 0.35
  local ok_commit, val_commit = core.set_fx_wet(tr, child2_id, 0.35, true, 1.0)
  assert_true(ok_commit, "set_fx_wet on release succeeds")
  assert_eq(val_commit, 0.35, "applied wet == 0.35")
  assert_eq(#r._state.undo_history, undo_before + 1, "record_undo=true adds 1 undo entry")
  local last_block = r._state.undo_blocks[#r._state.undo_blocks]
  assert_eq(last_block.begin_wet[child2_guid], 1.0, "Undo_BeginBlock captured pre-drag baseline wet 1.0")
  assert_eq(last_block.end_wet[child2_guid], 0.35, "Undo_EndBlock captured final wet 0.35")

  assert_true(core.set_fx_wet(tr, norm1_id, 0.68), "set_fx_wet on normal fx succeeds")

  vm = core.build_view_model(tr)
  assert_eq(vm.strip.children[2].wet, 0.35, "strip child 2 wet updated to 0.35")
  assert_eq(vm.strip.children[2].wet_percent, 35, "strip child 2 wet_percent == 35")
  assert_eq(vm.normal_fx[1].wet, 0.68, "normal fx 1 wet updated to 0.68")
  assert_eq(vm.normal_fx[1].wet_percent, 68, "normal fx 1 wet_percent == 68")

  -- 9.3 边界夹紧 (<0 夹紧至 0.0, >1 夹紧至 1.0) 与非法输入拦截
  local ok_low, clamped_low = core.set_fx_wet(tr, child2_id, -0.5)
  assert_true(ok_low, "negative wet clamped ok")
  assert_eq(clamped_low, 0.0, "negative wet clamped to 0.0")
  local _, read_low = core.get_fx_wet(tr, child2_id)
  assert_eq(read_low, 0.0, "get_fx_wet reads 0.0")

  local ok_high, clamped_high = core.set_fx_wet(tr, child2_id, 2.5)
  assert_true(ok_high, "wet > 1 clamped ok")
  assert_eq(clamped_high, 1.0, "wet > 1 clamped to 1.0")

  assert_false(core.set_fx_wet(tr, child2_id, 0 / 0), "reject NaN wet value")
  assert_false(core.set_fx_wet(tr, child2_id, "0.5"), "reject non-number wet value")
  assert_false(core.set_fx_wet(tr, 999, 0.5), "reject out-of-bounds top-level fx_id")
  local oob_child = core.encode_container_item_index(0, 9, r.TrackFX_GetCount(tr))
  assert_false(core.set_fx_wet(tr, oob_child, 0.5), "reject out-of-bounds container child fx_id")

  -- 9.4 当 TrackFX_GetParamFromIdent 不可用时，自动回退至 TrackFX_GetNumParams + TrackFX_GetParamName("Wet")
  r.TrackFX_GetParamFromIdent = nil
  assert_true(core.set_fx_wet(tr, child2_id, 0.25), "fallback set_fx_wet without TrackFX_GetParamFromIdent")
  local ok_fb, val_fb = core.get_fx_wet(tr, child2_id)
  assert_true(ok_fb, "fallback get_fx_wet succeeds")
  assert_eq(val_fb, 0.25, "fallback get_fx_wet reads 0.25")
end)

--------------------------------------------------------------------------------
-- 用例 10 (v0.2.0)：双区完整操作闭环（双向拖拽排序 from<to / from>to、跨偏离容器排序与干湿比跟随）
--------------------------------------------------------------------------------
run_test("v0.2.0 双区完整操作闭环（双向排序 from<to & from>to、跨偏离容器排序与状态保持）", function(r)
  local tr = r.mock_add_track("Full Loop Track")

  -- 10.1 上半区添加 4 个子插件并各自设置不同干湿比
  core.add_fx_to_strip(tr, "VST3: StripA")
  core.add_fx_to_strip(tr, "VST3: StripB")
  core.add_fx_to_strip(tr, "VST3: StripC")
  core.add_fx_to_strip(tr, "VST3: StripD")

  local vm = core.build_view_model(tr)
  core.set_fx_wet(tr, vm.strip.children[1].fx_id, 0.10)
  core.set_fx_wet(tr, vm.strip.children[2].fx_id, 0.20)
  core.set_fx_wet(tr, vm.strip.children[3].fx_id, 0.30)
  core.set_fx_wet(tr, vm.strip.children[4].fx_id, 0.40)

  -- 上半区正向拖拽 (from < to)：将槽位 1 (StripA, 10%) 拖至槽位 4
  assert_true(core.move_strip_fx(tr, 1, 4), "move_strip_fx 1 -> 4 (from < to)")
  vm = core.build_view_model(tr)
  assert_eq(vm.strip.children[1].name, "VST3: StripB", "after 1->4: slot 1 is StripB")
  assert_eq(vm.strip.children[2].name, "VST3: StripC", "after 1->4: slot 2 is StripC")
  assert_eq(vm.strip.children[3].name, "VST3: StripD", "after 1->4: slot 3 is StripD")
  assert_eq(vm.strip.children[4].name, "VST3: StripA", "after 1->4: slot 4 is StripA")
  assert_eq(vm.strip.children[4].wet_percent, 10, "StripA kept 10% wet after move 1->4")

  -- 上半区反向拖拽 (from > to)：将槽位 3 (StripD, 40%) 拖至槽位 1
  assert_true(core.move_strip_fx(tr, 3, 1), "move_strip_fx 3 -> 1 (from > to)")
  vm = core.build_view_model(tr)
  assert_eq(vm.strip.children[1].name, "VST3: StripD", "after 3->1: slot 1 is StripD")
  assert_eq(vm.strip.children[1].wet_percent, 40, "StripD kept 40% wet after move 3->1")
  assert_eq(vm.strip.children[2].name, "VST3: StripB", "after 3->1: slot 2 is StripB")

  -- 10.2 下半区添加 3 个常规插件，并模拟 0 号位容器偏离至中间 (top_index 1) 时的跨容器边界排序
  core.add_normal_fx(tr, "VST3: Norm1")
  core.add_normal_fx(tr, "VST3: Norm2")
  core.add_normal_fx(tr, "VST3: Norm3")

  -- 将 Strip 容器从 top_index 0 移至 top_index 1
  -- 此时顶层链：[0: Norm1, 1: StripContainer, 2: Norm2, 3: Norm3]
  r.TrackFX_CopyToTrack(tr, 0, tr, 1, true)
  vm = core.build_view_model(tr)
  assert_true(vm.strip.is_displaced, "strip displaced to index 1")
  assert_eq(vm.normal_fx[1].name, "VST3: Norm1", "displaced normal 1 is Norm1 (top 0)")
  assert_eq(vm.normal_fx[2].name, "VST3: Norm2", "displaced normal 2 is Norm2 (top 2)")
  assert_eq(vm.normal_fx[3].name, "VST3: Norm3", "displaced normal 3 is Norm3 (top 3)")

  -- 在容器偏离在中间时，将下半区 visual_slot 1 (Norm1) 正向拖到 visual_slot 3 (Norm3)
  assert_true(core.move_normal_fx(tr, 1, 3), "move_normal_fx 1 -> 3 across displaced strip")
  vm = core.build_view_model(tr)
  assert_true(vm.strip.initialized, "strip container still initialized")
  assert_eq(#vm.strip.children, 4, "all 4 strip children untouched")
  assert_eq(vm.normal_fx[1].name, "VST3: Norm2", "after 1->3: normal slot 1 is Norm2")
  assert_eq(vm.normal_fx[2].name, "VST3: Norm3", "after 1->3: normal slot 2 is Norm3")
  assert_eq(vm.normal_fx[3].name, "VST3: Norm1", "after 1->3: normal slot 3 is Norm1")
end)

--------------------------------------------------------------------------------
-- 用例 11 (v0.2.0)：Synth / 虚拟乐器插件（VSTi/VST3i/CLAPi/AUi/LV2i/DXi 与 fxtags）默认过滤与切换
--------------------------------------------------------------------------------
run_test("v0.2.0 Synth 虚拟乐器插件识别、默认过滤与 include_instruments 按需包含", function(r)
  r.mock_set_installed_fx({
    { name = "Container", ident = "Container" },
    { name = "VST3: ReaEQ (Cockos)", ident = "reaeq.vst3" },
    { name = "VST: SSL G-Master Buss Compressor (Waves)", ident = "SSLComp.dll" },
    { name = "JS: 1175 Compressor [Stillwell]", ident = "stillwell/1175" },
    { name = "VST3i: Kontakt 7 (Native Instruments) (64 out)", ident = "Kontakt 7.vst3" },
    { name = "VSTi: ReaSynth (Cockos)", ident = "reasynth.dll" },
    { name = "CLAPi: Surge XT (Surge Synth Team)", ident = "org.surge-synth-team.surge-xt" },
    { name = "AUi: Alchemy (Apple)", ident = "Alchemy.component" },
    { name = "LV2i: Helm (Matt Tytel)", ident = "http://tytel.org/helm" },
    { name = "VST3: Custom Tagged Synth (MockDev)", ident = "tagged_synth.vst3" },
  })

  r.mock_set_resource_file("reaper-fxtags.ini", [[
[category]
tagged_synth.vst3=Instrument|Synth
]])

  -- 11.1 格式与标签识别断言
  assert_true(core.is_instrument_format("VSTi"), "VSTi is instrument format")
  assert_true(core.is_instrument_format("vst3i"), "vst3i is instrument format")
  assert_true(core.is_instrument_format("CLAPi"), "CLAPi is instrument format")
  assert_true(core.is_instrument_format("AUi"), "AUi is instrument format")
  assert_true(core.is_instrument_format("LV2i"), "LV2i is instrument format")
  assert_true(core.is_instrument_format("DXi"), "DXi is instrument format")
  assert_false(core.is_instrument_format("VST3"), "VST3 is not instrument format")
  assert_false(core.is_instrument_format("CLAP"), "CLAP is not instrument format")
  assert_false(core.is_instrument_format("JS"), "JS is not instrument format")
  assert_true(core.is_instrument_fx("VST3: Lead (Dev)", "Synth|Lead"), "Synth|Lead tag is instrument")
  assert_true(core.is_instrument_fx("VST3: Pad (Dev)", "Generator|Instrument"), "Generator|Instrument tag is instrument")
  assert_false(core.is_instrument_fx("VST3: Comp (Dev)", "Dynamics|Compressor"), "Dynamics|Compressor tag is not instrument")

  -- 11.2 get_installed_fx 包含全量非 Container 插件（9 项），且准确标记 is_instrument
  local all_fx = core.get_installed_fx(true)
  assert_eq(#all_fx, 9, "9 total non-Container plugins cached")
  assert_false(all_fx[1].is_instrument, "ReaEQ is not instrument")
  assert_true(all_fx[4].is_instrument, "VST3i Kontakt 7 is instrument")
  assert_eq(all_fx[4].developer, "Native Instruments", "Kontakt 7 developer stripped (64 out)")
  assert_true(all_fx[5].is_instrument, "VSTi ReaSynth is instrument")
  assert_true(all_fx[6].is_instrument, "CLAPi Surge XT is instrument")
  assert_true(all_fx[7].is_instrument, "AUi Alchemy is instrument")
  assert_true(all_fx[8].is_instrument, "LV2i Helm is instrument")
  assert_true(all_fx[9].is_instrument, "fxtags Instrument|Synth marked as instrument")

  -- 11.3 filter_installed_fx 默认过滤所有 Synth / 乐器插件，仅返回 3 个音频效果器
  local fx_only, total_fx_only = core.filter_installed_fx("")
  assert_eq(total_fx_only, 3, "default filter_installed_fx excludes all 6 instruments")
  assert_eq(#fx_only, 3, "only 3 audio effects returned by default")
  assert_eq(fx_only[1].name, "VST3: ReaEQ (Cockos)", "audio effect 1")
  assert_eq(fx_only[2].name, "VST: SSL G-Master Buss Compressor (Waves)", "audio effect 2")
  assert_eq(fx_only[3].name, "JS: 1175 Compressor [Stillwell]", "audio effect 3")

  -- 11.4 开启 include_instruments = true 后可检索到全部 9 个插件（含 Synth）
  local with_inst, total_with_inst = core.filter_installed_fx("", nil, false, { include_instruments = true })
  assert_eq(total_with_inst, 9, "include_instruments=true returns all 9 plugins")
  assert_eq(#with_inst, 9, "9 plugins in list when include_instruments=true")

  local surge_res, surge_cnt = core.filter_installed_fx("surge", nil, false, { include_instruments = false })
  assert_eq(surge_cnt, 0, "searching synth name while include_instruments=false returns 0")
  local surge_on, surge_on_cnt = core.filter_installed_fx("surge", nil, false, { include_instruments = true })
  assert_eq(surge_on_cnt, 1, "searching synth name while include_instruments=true returns 1")
  assert_eq(surge_on[1].name, "CLAPi: Surge XT (Surge Synth Team)", "matched CLAPi Surge XT")

  -- 11.5 4 个被 REAPER 标为 DXi: 的已知音频效果器硬编码豁免例外，以及运行内扫描 DX (reaper-dxplugins64.ini + EnumInstalledFX(-1)) 增量刷新兜底
  assert_true(core.is_dxi_effect_exception("DXi: Sonitus:fx Delay"), "Sonitus:fx Delay is DXi effect exception")
  assert_true(core.is_dxi_effect_exception("DXi: Cakewalk Tempo Delay"), "Cakewalk Tempo Delay is DXi effect exception")
  assert_true(core.is_dxi_effect_exception("DXi: Cakewalk Classic Phaser"), "Cakewalk Classic Phaser is DXi effect exception")
  assert_true(core.is_dxi_effect_exception("DXi: Cakewalk Modfilter"), "Cakewalk Modfilter is DXi effect exception")
  assert_false(core.is_dxi_effect_exception("DXi: TTS-1 (Cakewalk)"), "TTS-1 is genuine DXi instrument")

  assert_false(core.is_instrument_fx("DXi: Sonitus:fx Delay"), "DXi: Sonitus:fx Delay exempted from instrument filter")
  assert_false(core.is_instrument_fx("DXi: Cakewalk Tempo Delay"), "DXi: Cakewalk Tempo Delay exempted from instrument filter")
  assert_false(core.is_instrument_fx("DXi: Cakewalk Classic Phaser"), "DXi: Cakewalk Classic Phaser exempted from instrument filter")
  assert_false(core.is_instrument_fx("DXi: Cakewalk Modfilter"), "DXi: Cakewalk Modfilter exempted from instrument filter")
  assert_true(core.is_instrument_fx("DXi: TTS-1 (Cakewalk)"), "DXi: TTS-1 identified as instrument")

  r.mock_set_installed_fx({
    { name = "VST3: ReaEQ (Cockos)", ident = "reaeq.vst3" },
    { name = "DX: Sonitus:fx Compressor", ident = "{3921B983-1029-11D3-A968-00A0C922E6EC}" },
  })
  r.mock_set_resource_file("reaper-dxplugins64.ini", [[
[{3921B983-1029-11D3-A968-00A0C922E6EC}]
Name=DX: Sonitus:fx Compressor
Load=1

[{3921B985-1029-11D3-A968-00A0C922E6EC}]
Name=DX: Sonitus:fx Equalizer
Load=1

[{3921B987-1029-11D3-A968-00A0C922E6EC}]
Name=DXi: Sonitus:fx Delay
Load=1

[{CAKEWALK-TEMPO-DELAY-GUID}]
Name=DXi: Cakewalk Tempo Delay
Load=1

[{CAKEWALK-PHASER-GUID}]
Name=DXi: Cakewalk Classic Phaser
Load=1

[{CAKEWALK-MODFILTER-GUID}]
Name=DXi: Cakewalk Modfilter
Load=1

[{CAKEWALK-TTS1-GUID}]
Name=DXi: TTS-1 (Cakewalk)
Load=1

[{00000000-0000-0000-0000-000000000000}]
Name=DX: Disabled NonPlugin Codec
Load=0
]])

  local refresh_cnt_before = r._state.enum_installed_fx_refresh_count or 0
  local merged_all = core.get_installed_fx(true)
  assert_eq((r._state.enum_installed_fx_refresh_count or 0), refresh_cnt_before + 1, "force_refresh calls EnumInstalledFX(-1)")
  -- 应包含：ReaEQ + Sonitus Compressor (已由 EnumInstalledFX 返回，去重不重复) + 新合并的 5 个 DX/DXi 效果器 + 1 个 DXi TTS-1 乐器 = 8 项 (Load=0 被忽略)
  assert_eq(#merged_all, 8, "reaper-dxplugins64.ini Load=1 entries merged and deduplicated while Load=0 ignored")

  local dx_fx_only, dx_fx_total = core.filter_installed_fx("", nil, false, { include_instruments = false })
  assert_eq(dx_fx_total, 7, "default filter keeps all 4 DXi effect exceptions + 2 DX effects + ReaEQ, and hides DXi TTS-1")
  assert_eq(#dx_fx_only, 7, "7 audio effects returned when include_instruments=false")
end)

--------------------------------------------------------------------------------
-- 用例 12 (v0.2.0)：插件分组体系（reaper-fxfolders.ini、reaper-fxtags.ini、分类/厂商/格式分组与脚本内自定义分组）
--------------------------------------------------------------------------------
run_test("v0.2.0 插件分组体系（fxfolders.ini 文件夹/智能文件夹、fxtags.ini、A-Z 分类与自定义分组持久化）", function(r)
  r.mock_set_installed_fx({
    { name = "VST3: Neve 1073 Preamp (UA) (stereo)", ident = "uaneve1073.vst3" },
    { name = "VST3: Pro-Q 3 (FabFilter)", ident = "FabFilter Pro-Q 3.vst3" },
    { name = "VST3: ReaEQ (Cockos) (8ch)", ident = "reaeq.vst3" },
    { name = "VST: SSL G-Master Buss Compressor (Waves)", ident = "SSLComp.dll" },
    { name = "JS: 1175 Compressor [Stillwell]", ident = "stillwell/1175" },
    { name = "VST3: VintageVerb (Valhalla DSP)", ident = "ValhallaVintageVerb.vst3" },
    { name = "JS: Volume Adjustment", ident = "utility/volume" },
    { name = "VST3i: ReaSynth (Cockos)", ident = "reasynth.vst3" },
  })

  r.mock_set_resource_file("reaper-fxtags.ini", [[
[category]
uaneve1073.vst3=Channel Strip
FabFilter_Pro_Q_3.vst3=EQ|Equalizer
SSLComp.dll=Dynamics

[developer]
uaneve1073.vst3=Universal Audio
]])

  r.mock_set_resource_file("reaper-fxfolders.ini", [[
[Folders]
NbFolders=2
Name0=Vocal Chain
Id0=0
Name1=All Compressors
Id1=1

[Folder0]
Nb=2
Item0=uaneve1073.vst3
Type0=3
Item1=FabFilter Pro-Q 3.vst3
Type1=3

[Folder1]
Nb=1
Item0=compressor
Type0=16777216
]])

  core.get_installed_fx(true)

  -- 12.1 脚本内自定义分组增删改查与 ExtState 持久化往返
  assert_false(core.add_custom_fx_group("   "), "reject empty custom group name")
  local ok_g1, g1_name = core.add_custom_fx_group("常用通道条")
  assert_true(ok_g1 and g1_name == "常用通道条", "created custom group 常用通道条")
  assert_true(core.assign_fx_to_custom_group("常用通道条", "uaneve1073.vst3"), "assign Neve to 常用通道条")
  assert_true(core.assign_fx_to_custom_group("常用通道条", "SSLComp.dll"), "assign SSLComp to 常用通道条")
  assert_true(core.assign_fx_to_custom_group("鼓组总线", "stillwell/1175"), "auto-create and assign to 鼓组总线")

  -- 强制从 ExtState 重新反序列化校验持久化
  local persisted_groups = core.get_custom_fx_groups(true)
  assert_eq(#persisted_groups, 2, "2 custom groups persisted in ExtState")
  assert_eq(persisted_groups[1].name, "常用通道条", "persisted group 1 name")
  assert_eq(#persisted_groups[1].items, 2, "persisted group 1 has 2 items")
  assert_true(core.is_fx_in_custom_group("常用通道条", "uaneve1073.vst3"), "Neve is in 常用通道条")

  -- 12.2 按默认 "category" 模式获取分组列表（默认隐藏 VST3i ReaSynth，共匹配 7 个效果器）
  -- 顺序应为：★ 自定义分组 -> 📁 reaper-fxfolders.ini 文件夹 -> 严格按 A–Z 纯字母序排列的功能分类（不强插人为置顶权重，且合并 EQ 不分裂）
  local cat_groups, cat_total = core.get_grouped_installed_fx("", "category", { include_instruments = false })
  assert_eq(cat_total, 7, "7 non-instrument FX matched")
  assert_eq(cat_groups[1].name, "★ 常用通道条", "top group 1 is custom group ★ 常用通道条")
  assert_eq(cat_groups[1].source, "custom", "group 1 source == custom")
  assert_eq(#cat_groups[1].items, 2, "★ 常用通道条 has 2 matched items")

  assert_eq(cat_groups[2].name, "★ 鼓组总线", "top group 2 is custom group ★ 鼓组总线")
  assert_eq(#cat_groups[2].items, 1, "★ 鼓组总线 has 1 matched item")

  assert_eq(cat_groups[3].name, "📁 Vocal Chain", "group 3 is REAPER fxfolder 📁 Vocal Chain")
  assert_eq(cat_groups[3].source, "fxfolder", "group 3 source == fxfolder")
  assert_eq(#cat_groups[3].items, 2, "📁 Vocal Chain matched Neve + Pro-Q 3")

  assert_eq(cat_groups[4].name, "📁 All Compressors", "group 4 is REAPER Smart Folder 📁 All Compressors")
  assert_eq(#cat_groups[4].items, 2, "Smart Folder 'compressor' matched SSLComp + 1175 Compressor")

  -- 校验后续功能分类严格按 A–Z 字母顺序排列：Channel Strip -> Dynamics -> EQ -> Reverb -> Utility
  assert_eq(cat_groups[5].name, "Channel Strip", "A-Z category 1: Channel Strip")
  assert_eq(cat_groups[6].name, "Dynamics", "A-Z category 2: Dynamics")
  assert_eq(#cat_groups[6].items, 2, "Dynamics has SSLComp and 1175")
  assert_eq(cat_groups[7].name, "EQ", "A-Z category 3: EQ (merged fxtags EQ and inferred ReaEQ)")
  assert_eq(#cat_groups[7].items, 2, "EQ has both Pro-Q 3 and ReaEQ without EQ & Filter split")
  assert_eq(cat_groups[8].name, "Reverb", "A-Z category 4: Reverb")
  assert_eq(cat_groups[9].name, "Utility", "A-Z category 5: Utility")

  -- 12.3 按 "developer"（厂商）与 "format"（格式）与 "custom" 分组校验
  local dev_groups = core.get_grouped_installed_fx("", "developer", { include_instruments = false })
  assert_true(#dev_groups >= 6, "grouped by developer")
  -- 校验 uaneve1073 的 developer 被 reaper-fxtags.ini 覆盖为 Universal Audio，且 ReaEQ (Cockos) (8ch) 提取为 Cockos
  local found_ua, found_cockos = false, false
  for _, g in ipairs(dev_groups) do
    if g.name == "Universal Audio" and #g.items == 1 then
      found_ua = true
    elseif g.name == "Cockos" and #g.items == 1 then
      found_cockos = true
    end
  end
  assert_true(found_ua, "fxtags [developer] Universal Audio recognized")
  assert_true(found_cockos, "Cockos extracted cleanly even with trailing (8ch)")

  local fmt_groups = core.get_grouped_installed_fx("", "format", { include_instruments = false })
  assert_eq(#fmt_groups, 3, "3 effect formats: JS, VST, VST3")

  -- 12.4 从自定义分组移除单个插件与删除整组
  assert_true(core.remove_fx_from_custom_group("常用通道条", "SSLComp.dll"), "remove SSLComp from 常用通道条")
  assert_false(core.is_fx_in_custom_group("常用通道条", "SSLComp.dll"), "SSLComp no longer in 常用通道条")
  assert_true(core.remove_custom_fx_group("鼓组总线"), "remove entire custom group 鼓组总线")
  assert_eq(#core.get_custom_fx_groups(), 1, "1 custom group remains")

  -- 12.5 回归防御：厂商名含 Filter (如 FabFilter Pro-C 2 / Pro-R / Saturn 2 / Timeless 3 / Volcano 3) 推断至对齐 REAPER 原生的独立分类，
  --      且 Smart Folder 支持 NOT / OR / 引号短语，自定义分组精确匹配不得误命中同分类其他插件，
  --      且分组模式下 max_results 按单组截断而不丢失排在后面的分组
  assert_eq(core.infer_fx_category("VST3: Pro-C 2 (FabFilter)", "FabFilter Pro-C 2.vst3", nil, false), "Dynamics", "FabFilter Pro-C 2 inferred as Dynamics")
  assert_eq(core.infer_fx_category("VST3: Pro-R (FabFilter)", "FabFilter Pro-R.vst3", nil, false), "Reverb", "FabFilter Pro-R inferred as Reverb")
  assert_eq(core.infer_fx_category("VST3: Timeless 3 (FabFilter)", "FabFilter Timeless 3.vst3", nil, false), "Delay", "FabFilter Timeless 3 inferred as Delay")
  assert_eq(core.infer_fx_category("VST3: Volcano 3 (FabFilter)", "FabFilter Volcano 3.vst3", nil, false), "Filter", "FabFilter Volcano 3 inferred as Filter")
  assert_eq(core.infer_fx_category("VST3: Saturn 2 (FabFilter)", "FabFilter Saturn 2.vst3", nil, false), "Distortion", "FabFilter Saturn 2 inferred as Distortion")
  assert_eq(core.infer_fx_category("JS: Span Spectrum Analyzer", "analysis/span", nil, false), "Analyzer", "Analyzer plugin inferred as Analyzer")

  r.mock_set_resource_file("reaper-fxfolders.ini", [[
[Folders]
NbFolders=2
Name0=Non-Waves Compressors
Id0=0
Name1=UA or Valhalla
Id1=1

[Folder0]
Nb=1
Item0=compressor NOT waves
Type0=16777216

[Folder1]
Nb=1
Item0="Universal Audio" OR "Valhalla DSP"
Type0=16777216
]])
  core.get_installed_fx(true)

  -- 将名为 "delay" 的虚拟标识加入自定义分组，绝不能因为 VintageVerb 分类为 "Reverb & Delay" 而误命中 VintageVerb
  core.assign_fx_to_custom_group("仅Delay单项", "delay")
  local adv_groups = core.get_grouped_installed_fx("", "custom", { include_instruments = false })
  local non_waves_grp, ua_valhalla_grp, exact_delay_grp = nil, nil, nil
  for _, g in ipairs(adv_groups) do
    if g.raw_name == "Non-Waves Compressors" then
      non_waves_grp = g
    elseif g.raw_name == "UA or Valhalla" then
      ua_valhalla_grp = g
    elseif g.raw_name == "仅Delay单项" then
      exact_delay_grp = g
    end
  end
  assert_true(non_waves_grp ~= nil, "Smart Folder Non-Waves Compressors exists")
  assert_eq(#non_waves_grp.items, 1, "Smart Folder 'compressor NOT waves' excludes Waves SSLComp and keeps Stillwell 1175")
  assert_eq(non_waves_grp.items[1].ident, "stillwell/1175", "remaining compressor is stillwell/1175")

  assert_true(ua_valhalla_grp ~= nil, "Smart Folder UA or Valhalla exists")
  assert_eq(#ua_valhalla_grp.items, 2, "Smart Folder OR with quoted vendor phrases matched 2 plugins")

  assert_true(exact_delay_grp ~= nil, "Custom group 仅Delay单项 exists")
  assert_eq(#exact_delay_grp.items, 0, "exact custom group item 'delay' does not falsely match Reverb & Delay category")

  -- 分组模式下传入小 max_results = 1 时，所有分类依然保留，仅单组 items 被截断为 1
  local capped_cat_groups, capped_cat_total = core.get_grouped_installed_fx("", "category", { include_instruments = false, max_results = 1 })
  assert_eq(capped_cat_total, 7, "total_matched still 7 when max_results=1 in grouped mode")
  assert_true(#capped_cat_groups >= 7, "all non-empty groups preserved even with max_results=1")
  for _, g in ipairs(capped_cat_groups) do
    assert_true(#g.items <= 1, "each group items capped at max_results=1")
  end
end)

--------------------------------------------------------------------------------
-- 用例 13 (v0.2.0)：上下双区跨区互相拖拽/移动 FX（含未初始化自动建容器、指定槽位插入、状态保持与 0 号位容器保护）
--------------------------------------------------------------------------------
run_test("v0.2.0 上下双区跨区互相拖拽 FX（常规槽<->0 号位 Strip 双向移入移出、自动建容器与边界保护）", function(r)
  local tr = r.mock_add_track("Cross-Zone Drag Track")

  -- 13.1 初始状态：0 号位 Strip 未初始化，下半区有 3 个常规插件（NormA, NormB, NormC）
  core.add_normal_fx(tr, "VST3: NormA")
  core.add_normal_fx(tr, "VST3: NormB")
  core.add_normal_fx(tr, "VST3: NormC")

  local vm = core.build_view_model(tr)
  assert_false(vm.strip.initialized, "strip initially uninitialized")
  assert_eq(#vm.normal_fx, 3, "3 normal FX initially")

  -- 为 NormB 设置 45% 干湿比，并记录其 GUID
  local norm_b_guid = vm.normal_fx[2].guid
  core.set_fx_wet(tr, vm.normal_fx[2].fx_id, 0.45)

  -- 将下半区 visual_slot 2 (NormB) 拖入尚未初始化的上半区 0 号位 Strip
  assert_true(core.move_normal_fx_to_strip(tr, 2, nil), "move normal slot 2 into uninitialized strip auto-creates container")

  vm = core.build_view_model(tr)
  assert_true(vm.strip.initialized, "strip auto-initialized at slot 0")
  assert_eq(vm.strip.container_index, 0, "strip container at top_index 0")
  assert_eq(#vm.strip.children, 1, "strip now has 1 child")
  assert_eq(vm.strip.children[1].name, "VST3: NormB", "strip child 1 is NormB")
  assert_eq(vm.strip.children[1].guid, norm_b_guid, "NormB GUID preserved after moving into strip")
  assert_eq(vm.strip.children[1].wet_percent, 45, "NormB 45% wet preserved after moving into strip")

  assert_eq(#vm.normal_fx, 2, "2 normal FX remain in lower zone")
  assert_eq(vm.normal_fx[1].name, "VST3: NormA", "normal slot 1 is NormA")
  assert_eq(vm.normal_fx[2].name, "VST3: NormC", "normal slot 2 is NormC")

  -- 13.2 将下半区 visual_slot 2 (NormC) 拖入上半区 Strip 的指定 1 号子槽位（插入到 NormB 之前）
  assert_true(core.move_normal_fx_to_strip(tr, 2, 1), "move normal slot 2 (NormC) into strip slot 1")
  vm = core.build_view_model(tr)
  assert_eq(#vm.strip.children, 2, "strip now has 2 children")
  assert_eq(vm.strip.children[1].name, "VST3: NormC", "strip slot 1 is NormC")
  assert_eq(vm.strip.children[2].name, "VST3: NormB", "strip slot 2 is NormB")
  assert_eq(#vm.normal_fx, 1, "1 normal FX remains (NormA)")
  assert_eq(vm.normal_fx[1].name, "VST3: NormA", "remaining normal slot 1 is NormA")

  -- 13.3 将上半区 Strip 子槽位 2 (NormB, 45% wet) 拖回下半区常规 FX 槽位 1 (插入到 NormA 之前)
  -- 核心边界校验：0 号位 Strip 容器必须稳居 top_index 0，绝不能被挤到 index 1 或被覆盖！
  local strip_guid = vm.strip.container_guid
  assert_true(core.move_strip_fx_to_normal(tr, 2, 1), "move strip slot 2 (NormB) out to normal visual_slot 1")
  vm = core.build_view_model(tr)
  assert_true(vm.strip.initialized, "strip container still initialized")
  assert_eq(vm.strip.container_index, 0, "strip container remains at top_index 0 (not displaced)")
  assert_eq(vm.strip.container_guid, strip_guid, "strip container GUID untouched")
  assert_false(vm.strip.is_displaced, "strip is not displaced")
  assert_eq(#vm.strip.children, 1, "1 child remains in strip (NormC)")
  assert_eq(vm.strip.children[1].name, "VST3: NormC", "remaining strip slot 1 is NormC")

  assert_eq(#vm.normal_fx, 2, "2 normal FX in lower zone")
  assert_eq(vm.normal_fx[1].name, "VST3: NormB", "normal slot 1 is now NormB")
  assert_eq(vm.normal_fx[1].top_index, 1, "normal slot 1 is at top_index 1 (after strip container)")
  assert_eq(vm.normal_fx[1].wet_percent, 45, "NormB kept 45% wet after moving back to normal zone")
  assert_eq(vm.normal_fx[2].name, "VST3: NormA", "normal slot 2 is NormA")
  assert_eq(vm.normal_fx[2].top_index, 2, "normal slot 2 is at top_index 2")

  -- 13.4 将上半区最后一个子插件 (NormC) 拖出至下半区末尾 (to_visual_slot = nil)
  -- 校验 0 号位容器变空后本体依然保留在 top_index 0，绝不被误删
  assert_true(core.move_strip_fx_to_normal(tr, 1, nil), "move last strip child out to end of normal zone")
  vm = core.build_view_model(tr)
  assert_true(vm.strip.initialized, "empty strip container still initialized at slot 0")
  assert_eq(vm.strip.container_index, 0, "empty strip container still at top_index 0")
  assert_eq(#vm.strip.children, 0, "strip container is now empty")
  assert_eq(#vm.normal_fx, 3, "all 3 FX now in lower normal zone")
  assert_eq(vm.normal_fx[1].name, "VST3: NormB", "normal 1 is NormB")
  assert_eq(vm.normal_fx[2].name, "VST3: NormA", "normal 2 is NormA")
  assert_eq(vm.normal_fx[3].name, "VST3: NormC", "normal 3 is NormC")

  -- 13.5 0 号位容器处于偏离状态 (如 top_index = 2) 时的跨区移入与移出，以及非法参数边界拦截
  -- 当前顶层：[0: Strip, 1: NormB, 2: NormA, 3: NormC] -> 将 Strip 移至 top_index 2：[0: NormB, 1: NormA, 2: Strip, 3: NormC]
  r.TrackFX_CopyToTrack(tr, 0, tr, 2, true)
  -- 将位于偏离容器之前的 normal slot 1 (NormB, top_index 0) 移入偏离容器
  assert_true(core.move_normal_fx_to_strip(tr, 1, nil), "move normal slot 1 (before displaced strip) into displaced strip")
  vm = core.build_view_model(tr)
  assert_eq(#vm.strip.children, 1, "displaced strip received NormB")
  assert_eq(vm.strip.children[1].name, "VST3: NormB", "displaced strip child 1 is NormB")
  assert_eq(#vm.normal_fx, 2, "2 normal FX remain (NormA, NormC)")

  -- 非法越界参数防御
  assert_false(core.move_normal_fx_to_strip(tr, 0, 1), "reject normal slot 0")
  assert_false(core.move_normal_fx_to_strip(tr, 99, 1), "reject normal slot > N")
  assert_false(core.move_normal_fx_to_strip(tr, 1, 99), "reject target strip slot > M+1")
  assert_false(core.move_strip_fx_to_normal(tr, 0, 1), "reject strip slot 0")
  assert_false(core.move_strip_fx_to_normal(tr, 99, 1), "reject strip slot > M")
  assert_false(core.move_strip_fx_to_normal(tr, 1, 0), "reject target normal visual_slot 0")
  assert_false(core.move_strip_fx_to_normal(tr, 1, 99), "reject target normal visual_slot > N+1")
end)

--------------------------------------------------------------------------------
-- 汇总结果与退出码
--------------------------------------------------------------------------------
_G.reaper = host_reaper
core.set_reaper(nil)

log_line("------------------------------------------------------------")
log_line(string.format("Total: %d | Passed: %d | Failed: %d", total_tests, passed_tests, failed_tests))
log_line("------------------------------------------------------------")

if failed_tests > 0 then
  if not host_reaper then
    os.exit(1)
  else
    error(string.format("Unit tests failed (%d/%d)", failed_tests, total_tests))
  end
end
