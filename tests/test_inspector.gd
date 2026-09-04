extends SceneTree

## A self-test of the debug part: the recorder, statistics, diagnostics, the
## report and the inspector facade.
##
##   godot --headless --script res://addons/aegis_ecs/tests/test_inspector.gd
##
## The most interesting case is spike attribution: a system that is cheap on
## average but occasionally expensive must rank above a system that is expensive
## evenly, because the player only feels a hitch from the first. This is checked
## with two systems whose behaviour is arranged to differ in exactly that way.

const TYPE_A: int = 0
const TYPE_TAG: int = 1

var _failures: int = 0


class DemoStore extends EcsPackedStore:
	var health: PackedFloat32Array = PackedFloat32Array()
	var position: PackedVector3Array = PackedVector3Array()

	func _init() -> void:
		track(&"health", &"position")


## Costs roughly the same every frame.
class SteadySystem extends EcsSystem:
	var work: int = 900

	func _init() -> void:
		system_name = "Steady"
		complete_access_metadata()

	func execute(_delta: float) -> void:
		var sink: float = 0.0
		for i in work:
			sink += sqrt(float(i))


## Almost always cheap, expensive once every [member period] frames — the exact
## shape that causes hitches while barely moving the average.
class SpikySystem extends EcsSystem:
	var period: int = 10
	var burst: int = 9000
	var frames: int = 0

	func _init() -> void:
		system_name = "Spiky"
		complete_access_metadata()

	func execute(_delta: float) -> void:
		frames += 1
		if frames % period != 0:
			return
		var sink: float = 0.0
		for i in burst:
			sink += sqrt(float(i))


class PausableSystem extends EcsSystem:
	func _init() -> void:
		system_name = "Pausable"
		requires_time = true
		complete_access_metadata()


class IdleSystem extends EcsSystem:
	func _init(display_name: String) -> void:
		system_name = display_name
		complete_access_metadata()


func _init() -> void:
	print("=== Aegis ECS: inspector self-test ===")
	_test_core_additions()
	_test_recorder_basics()
	_test_recorder_ring_wrap()
	_test_recorder_statuses()
	_test_stats_distribution()
	_test_spike_attribution()
	_test_diagnostics()
	_test_report()
	_test_inspector_facade()
	print("RESULT: %s" % ("OK" if _failures == 0 else "FAILED (%d)" % _failures))
	quit(1 if _failures > 0 else 0)


# --- core additions the debug part relies on -------------------------------

func _test_core_additions() -> void:
	var world := EcsWorld.new(32)
	var store := DemoStore.new()
	world.register_store(store, TYPE_A)

	# Inner classes have no global name, so this checks the fallback; a store
	# declared with class_name would report that name.
	_expect(not store.get_debug_name().is_empty(), "get_debug_name() never returns empty")
	store.debug_name = "Demo"
	_expect(store.get_debug_name() == "Demo", "explicit debug_name wins")

	var entity: int = world.create_entity()
	var slot: int = store.attach(entity)
	store.health[slot] = 42.0
	store.position[slot] = Vector3(1.0, 2.0, 3.0)

	_expect(store.get_field_value(0, slot) == 42.0, "get_field_value() reads a float field")
	_expect(store.get_field_value(1, slot) == Vector3(1.0, 2.0, 3.0),
		"get_field_value() reads a vector field")
	_expect(store.get_field_value(9, slot) == null, "get_field_value() rejects a bad field index")
	_expect(store.get_field_value(0, 999) == null, "get_field_value() rejects a bad slot")

	var described: Dictionary = store.describe_entity(entity)
	_expect(described.size() == 2 and described[&"health"] == 42.0,
		"describe_entity() returns every tracked field")
	_expect(store.describe_entity(entity + 1).is_empty(),
		"describe_entity() is empty for an entity without the component")

	var scheduler := EcsScheduler.new()
	scheduler.add_system(IdleSystem.new("A"), 100)
	scheduler.add_system(IdleSystem.new("B"), 200)
	scheduler.setup_all(world, null)
	_expect(scheduler.is_phase_allowed(0), "is_phase_allowed() is true by default")
	scheduler.set_phase_enabled(100, false)
	_expect(not scheduler.is_phase_allowed(0) and scheduler.is_phase_allowed(1),
		"is_phase_allowed() distinguishes a disabled phase from a disabled system")


# --- recorder ------------------------------------------------------------

func _test_recorder_basics() -> void:
	var harness := _build_harness()
	var recorder := EcsFrameRecorder.new()
	_expect(recorder.configure(harness.scheduler, harness.world, 64), "recorder configures")
	_expect(not EcsFrameRecorder.new().configure(null, null), "recorder rejects a null pipeline")
	_expect(recorder.get_frame_count() == 0, "recorder starts empty")

	for frame in 10:
		harness.scheduler.execute_all(1.0 / 60.0)
		recorder.capture()

	_expect(recorder.get_frame_count() == 10, "recorder holds every captured frame")
	_expect(recorder.get_frames_seen() == 10, "recorder counts frames seen")
	var newest: int = recorder.get_newest_slot()
	_expect(recorder.get_frame_id(newest) == 9, "newest slot carries the latest frame id")
	_expect(recorder.get_frame_total_usec(newest) > 0.0, "a captured frame has a non-zero total")
	_expect(recorder.get_frame_live_count(newest) == harness.world.get_live_count(),
		"the frame records the live entity count")
	_expect(recorder.last_capture_usec > 0.0, "the recorder measures its own cost")

	recorder.clear()
	_expect(recorder.get_frame_count() == 0, "clear() empties the window")


func _test_recorder_ring_wrap() -> void:
	var harness := _build_harness()
	var recorder := EcsFrameRecorder.new()
	recorder.configure(harness.scheduler, harness.world, 8)
	for frame in 20:
		harness.scheduler.execute_all(1.0 / 60.0)
		recorder.capture()

	_expect(recorder.get_frame_count() == 8, "the ring keeps exactly its capacity")
	_expect(recorder.get_frames_seen() == 20, "frames seen keeps counting past the ring")

	# Oldest to newest should be frames 12..19 in order.
	var ordered := true
	for index in 8:
		var slot: int = recorder.get_slot_in_order(index)
		ordered = ordered and recorder.get_frame_id(slot) == 12 + index
	_expect(ordered, "get_slot_in_order() walks the wrapped ring oldest-first")

	var by_age := true
	for age in 8:
		var slot: int = recorder.get_slot_from_newest(age)
		by_age = by_age and recorder.get_frame_id(slot) == 19 - age
	_expect(by_age, "get_slot_from_newest() walks backwards from the newest frame")
	_expect(recorder.get_slot_from_newest(99) == -1, "out-of-window ages return -1")


func _test_recorder_statuses() -> void:
	var world := EcsWorld.new(16)
	var scheduler := EcsScheduler.new()
	var pausable := PausableSystem.new()
	var switched := IdleSystem.new("Switched")
	var phased := IdleSystem.new("Phased")
	scheduler.add_system(pausable, 100)
	scheduler.add_system(switched, 100)
	scheduler.add_system(phased, 200)
	scheduler.setup_all(world, null)

	var recorder := EcsFrameRecorder.new()
	recorder.configure(scheduler, world, 8)

	scheduler.set_system_enabled(1, false)
	scheduler.set_phase_enabled(200, false)
	scheduler.execute_all(0.0)
	recorder.capture()

	var slot: int = recorder.get_newest_slot()
	_expect(recorder.get_status(slot, 0) == EcsFrameRecorder.Status.SKIPPED_PAUSED,
		"a requires_time system on a zero step is recorded as paused")
	_expect(recorder.get_status(slot, 1) == EcsFrameRecorder.Status.DISABLED,
		"a switched-off system is recorded as disabled")
	_expect(recorder.get_status(slot, 2) == EcsFrameRecorder.Status.PHASE_OFF,
		"a system in a disabled phase is recorded as phase-off")
	_expect(recorder.system_requires_time(0) and not recorder.system_requires_time(1),
		"the recorder remembers which systems depend on time")


# --- statistics --------------------------------------------------------

func _test_stats_distribution() -> void:
	var harness := _build_harness()
	var recorder := EcsFrameRecorder.new()
	recorder.configure(harness.scheduler, harness.world, 120)
	for frame in 120:
		harness.scheduler.execute_all(1.0 / 60.0)
		recorder.capture()

	var stats := EcsFrameStats.new()
	_expect(stats.analyse(recorder), "stats analyse a filled window")
	_expect(not EcsFrameStats.new().analyse(EcsFrameRecorder.new()),
		"stats refuse an unconfigured recorder")

	_expect(stats.get_frame_count() == 120, "stats cover the whole window")
	_expect(stats.get_frame_median_usec() <= stats.get_frame_p95_usec(),
		"median does not exceed p95")
	_expect(stats.get_frame_p95_usec() <= stats.get_frame_max_usec(),
		"p95 does not exceed max")
	_expect(stats.get_frame_min_usec() <= stats.get_frame_median_usec(),
		"min does not exceed the median")

	var worst: int = stats.get_worst_frame_slot()
	var worst_is_max := true
	for index in stats.get_frame_count():
		var slot: int = recorder.get_slot_in_order(index)
		if recorder.get_frame_total_usec(slot) > recorder.get_frame_total_usec(worst):
			worst_is_max = false
	_expect(worst_is_max, "the worst slot really holds the most expensive frame")

	var share_sum: float = 0.0
	for system in stats.get_system_count():
		share_sum += stats.get_system_share_percent(system)
	_expect(absf(share_sum - 100.0) < 0.5, "system shares add up to 100%%")

	var counts_ok := true
	for system in stats.get_system_count():
		counts_ok = counts_ok and stats.get_system_executed_frames(system) == 120
	_expect(counts_ok, "every system is recorded as having run every frame")


func _test_spike_attribution() -> void:
	var world := EcsWorld.new(16)
	var scheduler := EcsScheduler.new()
	var steady := SteadySystem.new()
	var spiky := SpikySystem.new()
	scheduler.add_system(steady)
	scheduler.add_system(spiky)
	scheduler.setup_all(world, null)

	var recorder := EcsFrameRecorder.new()
	recorder.configure(scheduler, world, 200)
	for frame in 200:
		scheduler.execute_all(1.0 / 60.0)
		recorder.capture()

	var stats := EcsFrameStats.new()
	stats.analyse(recorder)

	var steady_volatility: float = stats.get_system_volatility(0)
	var spiky_volatility: float = stats.get_system_volatility(1)
	_expect(spiky_volatility > steady_volatility * 2.0,
		"the bursty system is measurably less stable than the steady one")

	# The steady system costs more in total but contributes nothing to slow
	# frames. That distinction is why attribution exists.
	_expect(stats.get_system_excess_share(1) > stats.get_system_excess_share(0),
		"the bursty system owns more of the slow-frame excess than the steady one")
	_expect(stats.get_spike_contributor(0) == 1,
		"the bursty system is ranked the top spike contributor")
	_expect(stats.get_attributed_frame_count() > 0, "some frames were attributed")
	_expect(stats.get_total_excess_usec() > 0.0, "the attributed excess is non-zero")


# --- diagnostics ------------------------------------------------------

func _test_diagnostics() -> void:
	var diagnostics := EcsDiagnostics.new()

	# A full world must be flagged as critical.
	var full_world := EcsWorld.new(4)
	for i in 4:
		full_world.create_entity()
	var findings: Array = diagnostics.inspect(null, null, full_world)
	_expect(_has_finding(findings, "Entity capacity exhausted"),
		"a full world is reported")
	_expect(findings[0].severity == EcsDiagnostics.Finding.Severity.CRITICAL,
		"findings are sorted worst-first")

	# A destroy queue that is never drained: the classic symptom of a misplaced
	# reaper.
	var harness := _build_harness()
	for i in 5:
		harness.world.queue_destroy(i)
	var recorder := EcsFrameRecorder.new()
	recorder.configure(harness.scheduler, harness.world, 16)
	for frame in 16:
		harness.scheduler.execute_all(1.0 / 60.0)
		recorder.capture()
	var stats := EcsFrameStats.new()
	stats.analyse(recorder)
	findings = diagnostics.inspect(recorder, stats, harness.world)
	_expect(_has_finding(findings, "Destroy queue is not being drained"),
		"an undrained destroy queue is reported")

	# A grid with disproportionately more cells than objects.
	var sparse_grid := UniformSpatialGrid.new()
	sparse_grid.configure(200.0, 0.0, 1.0, 64)
	var ids := PackedInt32Array([0, 1, 2])
	var points := PackedVector3Array([Vector3.ZERO, Vector3.ONE, Vector3(2, 0, 2)])
	sparse_grid.rebuild(ids, points, 3)
	findings = diagnostics.inspect(null, null, null, {"grids": {"sparse": sparse_grid}})
	_expect(_has_finding(findings, "far more cells than objects"),
		"an over-provisioned grid is reported")

	# A clock that cannot keep up.
	var clock := SimulationClock.new()
	clock.fixed_step = 0.01
	clock.time_scale = 100.0
	clock.max_substeps = 2
	clock.advance(0.1)
	findings = diagnostics.inspect(null, null, null, {"clock": clock})
	_expect(_has_finding(findings, "Simulation cannot keep up"),
		"a saturated clock is reported")

	# A query whose cache never hits.
	var query_world := EcsWorld.new(32)
	var query_store := DemoStore.new()
	var query_tag := EcsTagStore.new()
	query_world.register_store(query_store, TYPE_A)
	query_world.register_store(query_tag, TYPE_TAG)
	for i in 8:
		var entity: int = query_world.create_entity()
		query_store.attach(entity)
	var query := EcsQuery.new()
	query.configure(query_world, PackedInt32Array([TYPE_A]), PackedInt32Array([TYPE_TAG]))

	var query_harness := _build_harness()
	var query_recorder := EcsFrameRecorder.new()
	query_recorder.configure(query_harness.scheduler, query_harness.world, 64)
	var thrash := EcsDiagnostics.new()
	thrash.inspect(query_recorder, null, null, {"queries": {"targets": query}})
	for frame in 40:
		query_harness.scheduler.execute_all(1.0 / 60.0)
		query_recorder.capture()
		# Membership churn every frame is what keeps the cache from ever hitting.
		query_tag.attach(0)
		query.refresh()
		query_tag.detach(0)
		query.refresh()
	findings = thrash.inspect(query_recorder, null, null, {"queries": {"targets": query}})
	_expect(_has_finding(findings, "rebuilds every frame"),
		"a query that rebuilds every frame is reported")

	# A healthy configuration must produce no critical findings.
	var clean := EcsDiagnostics.new()
	var clean_harness := _build_harness()
	findings = clean.inspect(null, null, clean_harness.world)
	var criticals: int = 0
	for finding in findings:
		if finding.severity == EcsDiagnostics.Finding.Severity.CRITICAL:
			criticals += 1
	_expect(criticals == 0, "a healthy world produces no critical findings")


# --- report ----------------------------------------------------------

func _test_report() -> void:
	var harness := _build_harness()
	var recorder := EcsFrameRecorder.new()
	recorder.configure(harness.scheduler, harness.world, 64)
	for frame in 64:
		harness.scheduler.execute_all(1.0 / 60.0)
		recorder.capture()
	var stats := EcsFrameStats.new()
	stats.analyse(recorder)

	var text: String = EcsReport.to_text(recorder, stats, harness.world)
	_expect(text.contains("frame cost") and text.contains("systems"),
		"the text report contains its main sections")
	_expect(EcsReport.to_text(null, null).contains("nothing recorded yet"),
		"the text report degrades gracefully with no data")

	var frame_text: String = EcsReport.frame_to_text(recorder, stats.get_worst_frame_slot(), stats)
	_expect(frame_text.contains("frame #"), "a single frame renders its own breakdown")
	_expect(EcsReport.frame_to_text(recorder, -1).contains("no such frame"),
		"an invalid slot is handled")

	var data: Dictionary = EcsReport.to_dictionary(recorder, stats, harness.world)
	_expect(data.has("frame") and data.has("systems") and data.has("world"),
		"the dictionary report carries frame, systems and world")
	_expect(data["systems"].size() == recorder.system_count,
		"every system appears in the dictionary report")
	_expect(JSON.stringify(data).length() > 0, "the dictionary report serialises to JSON")

	var csv: String = EcsReport.to_csv(recorder)
	var csv_lines: PackedStringArray = csv.split("\n")
	_expect(csv_lines.size() == 65, "the CSV has a header plus one row per frame")
	_expect(csv_lines[0].begins_with("frame,total_usec"), "the CSV header names its columns")


# --- facade --------------------------------------------------------

func _test_inspector_facade() -> void:
	var harness := _build_harness()

	var off := EcsInspector.attach(harness.scheduler, harness.world,
		{"mode": EcsInspector.Mode.OFF})
	off.capture()
	_expect(off.recorder.get_frame_count() == 0, "OFF mode records nothing")
	_expect(not off.has_panel(), "OFF mode has no panel")

	var telemetry := EcsInspector.attach(harness.scheduler, harness.world, {
		"mode": EcsInspector.Mode.TELEMETRY,
		"frames": 32,
		"budget_usec": 8000.0,
	})
	_expect(not telemetry.has_panel(), "TELEMETRY mode creates no panel")
	_expect(telemetry.diagnostics.frame_budget_usec == 8000.0, "the frame budget option is applied")

	for frame in 40:
		harness.scheduler.execute_all(1.0 / 60.0)
		telemetry.capture()
	_expect(telemetry.recorder.get_frame_count() == 32, "the frames option sizes the window")

	telemetry.refresh_now()
	_expect(telemetry.stats.is_analysed(), "refresh_now() analyses immediately")

	telemetry.add_counter_section("Combat", func() -> Array:
		return [["Kills", 7], ["Shots", 21]])
	_expect(telemetry.get_counter_section_count() == 1, "a counter section is registered")
	_expect(telemetry.get_counter_section_title(0) == "Combat", "the section keeps its title")
	var rows: Array = telemetry.get_counter_section_rows(0)
	_expect(rows.size() == 2 and rows[0][0] == "Kills", "the provider supplies rows on demand")

	telemetry.register_grid("main", UniformSpatialGrid.new())
	telemetry.set_clock(SimulationClock.new())
	_expect(telemetry.get_grids().has("main"), "a grid can be registered after attaching")
	_expect(telemetry.get_clock() != null, "a clock can be registered after attaching")

	var written: int = telemetry.save_report("user://")
	_expect(written == 3, "save_report() writes text, JSON and CSV")

	telemetry.detach()
	_expect(telemetry.mode == EcsInspector.Mode.OFF, "detach() switches the inspector off")


# --- helpers ------------------------------------------------------

class Harness extends RefCounted:
	var world: EcsWorld
	var scheduler: EcsScheduler
	var store: DemoStore


func _build_harness() -> Harness:
	var harness := Harness.new()
	harness.world = EcsWorld.new(64)
	harness.store = DemoStore.new()
	harness.world.register_store(harness.store, TYPE_A)
	harness.scheduler = EcsScheduler.new()
	harness.scheduler.add_system(SteadySystem.new())
	harness.scheduler.add_system(IdleSystem.new("Idle"))
	harness.scheduler.setup_all(harness.world, null)
	for i in 16:
		var entity: int = harness.world.create_entity()
		harness.store.attach(entity)
	return harness


func _has_finding(findings: Array, fragment: String) -> bool:
	for finding in findings:
		if finding.title.contains(fragment) or finding.detail.contains(fragment):
			return true
	return false


func _expect(condition: bool, label: String) -> void:
	if condition:
		print("  ok   %s" % label)
	else:
		_failures += 1
		print("  FAIL %s" % label)
