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
