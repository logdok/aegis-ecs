class_name EcsInspector
extends RefCounted

## One call that wires together recording, statistics, diagnostics and
## (optionally) the visual panel.
##
## [codeblock]
## var inspector := EcsInspector.attach(scheduler, world, {
##     "mode": EcsInspector.Mode.DEV,
##     "parent": $DebugLayer,          # remove it -- collection runs with no interface
##     "clock": simulation_clock,
##     "grids": { "enemies": enemy_grid },
##     "queries": { "targets": target_query },
## })
##
## func _process(delta: float) -> void:
##     scheduler.execute_all(delta)
##     inspector.capture()             # as the last line of the frame
## [/codeblock]
##
## [b]Modes.[/b] Collection is cheap enough to ship in release; the interface is
## not always wanted:
##
## [codeblock]
## Mode.OFF        nothing runs
## Mode.TELEMETRY  recording + diagnostics, no interface   <- safe in release
## Mode.INSPECTOR  + the panel, view only
## Mode.DEV        + controls that change the simulation
## [/codeblock]
##
## [b]The interface can be removed entirely.[/b] Delete `inspector/` or exclude
## it from the export preset — and this class keeps working with no panel: it
## resolves the panel through [method load] by path, not by class name, so a
## missing file is null, not a parse error that would take the whole game down
## with it.
##
## Everything the panel needs beyond the world — queries, grids, clocks, your own
## counters — lives outside the library, so it is passed in here rather than
## discovered. The core deliberately keeps no registry of it.

enum Mode {
	OFF = 0,
	## Recording and diagnostics, no interface. Cheap enough for a release build.
	TELEMETRY = 1,
	## Add the panel, view only.
	INSPECTOR = 2,
	## Add controls that change the simulation (disabling systems, step mode).
	DEV = 3,
}

const _PANEL_RELATIVE_PATH: String = "../inspector/ecs_inspector_panel.gd"

var mode: int = Mode.TELEMETRY

## How often the aggregates are recomputed, in hertz.
##
## Deliberately less often than the redraw: a median over hundreds of frames
## barely moves in a tenth of a second, so recomputing it more often buys
## nothing and spends real time. Recording still runs every frame: nothing is
## lost, only the summary is updated lazily.
var stats_refresh_hz: float = 2.0

## How often the diagnostics run, in hertz. Rarer still: findings change slowly,
## and some rules need a gap between measurements to measure a rate.
var diagnostics_refresh_hz: float = 0.5

var recorder := EcsFrameRecorder.new()
var stats := EcsFrameStats.new()
var diagnostics := EcsDiagnostics.new()

var _scheduler: EcsScheduler
var _world: EcsWorld
var _clock: SimulationClock
var _queries: Dictionary = {}
var _grids: Dictionary = {}
var _counter_sections: Array = []
var _findings: Array = []
var _panel: Node
var _last_capture_ticks: int = 0
var _stats_due_ticks: int = 0
var _diagnostics_due_ticks: int = 0
var _attached: bool = false


## Assembles the inspector and, if the mode and the parent node allow, the panel.
## Always returns an object — never null — so the calling code needs no
## branching.
static func attach(scheduler: EcsScheduler, world: EcsWorld, options: Dictionary = {}) -> EcsInspector:
	var inspector := EcsInspector.new()
	inspector.mode = int(options.get("mode", Mode.TELEMETRY))
	if inspector.mode == Mode.OFF:
		return inspector

	if not inspector.recorder.configure(scheduler, world, int(options.get("frames", EcsFrameRecorder.DEFAULT_FRAME_CAPACITY))):
		inspector.mode = Mode.OFF
		return inspector
	inspector._scheduler = scheduler
	inspector._world = world
	inspector._clock = options.get("clock")
	inspector._queries = options.get("queries", {}).duplicate()
	inspector._grids = options.get("grids", {}).duplicate()
	if options.has("budget_usec"):
		inspector.diagnostics.frame_budget_usec = float(options["budget_usec"])
	inspector._attached = true
	inspector._last_capture_ticks = Time.get_ticks_usec()

	var parent: Node = options.get("parent")
	if parent != null and inspector.mode >= Mode.INSPECTOR:
		inspector._create_panel(parent)
	return inspector


## Records the frame that just finished. Call it once, as the last action of the
## frame, after every phase has run.
func capture() -> void:
	if not _attached:
		return
	var now: int = Time.get_ticks_usec()
	var wall: float = float(now - _last_capture_ticks)
	_last_capture_ticks = now

	var substeps: int = 1
	if _clock != null:
		substeps = maxi(_clock.get_last_substeps(), 1)
	recorder.capture(substeps, wall)

	if now >= _stats_due_ticks:
		_stats_due_ticks = now + int(1_000_000.0 / maxf(stats_refresh_hz, 0.01))
		stats.analyse(recorder)
		if now >= _diagnostics_due_ticks:
			_diagnostics_due_ticks = now + int(1_000_000.0 / maxf(diagnostics_refresh_hz, 0.01))
			_findings = diagnostics.inspect(recorder, stats, _world, _build_extras())


## Forces an immediate recompute of the aggregates and diagnostics, ignoring the
## refresh rates. Use it before printing a report on demand.
func refresh_now() -> void:
	if not _attached:
		return
	stats.analyse(recorder)
	_findings = diagnostics.inspect(recorder, stats, _world, _build_extras())


## The diagnostics findings from the last run, worst first.
func get_findings() -> Array:
	return _findings


## Registers a group of application counters shown at the top of the panel.
##
## The library knows nothing about your game, so it cannot show "live enemies" or
## "core health" on its own. [param provider] returns rows as
## `[[label, value], ...]`; the values can be anything, they are stringified.
##
## It is called at the panel's refresh rate, not every frame, so even an
## expensive computation inside it does not touch the frame budget.
##
## [codeblock]
## inspector.add_counter_section("Population", func() -> Array:
##     return [
##         ["Active",      "%d / %d" % [my_store.count, my_target]],
##         ["Run total",   my_total],
##     ])
## [/codeblock]
func add_counter_section(title: String, provider: Callable) -> void:
	if not provider.is_valid():
		push_error("EcsInspector: the counter section '%s' has an invalid provider" % title)
		return
	_counter_sections.append({"title": title, "provider": provider})


func get_counter_section_count() -> int:
	return _counter_sections.size()


func get_counter_section_title(index: int) -> String:
	return _counter_sections[index]["title"]


## Evaluates one section. Returns rows as `[[label, value], ...]`.
func get_counter_section_rows(index: int) -> Array:
	var provider: Callable = _counter_sections[index]["provider"]
	if not provider.is_valid():
		return []
	var rows: Variant = provider.call()
	return rows if rows is Array else []


func register_query(name: String, query: EcsQuery) -> void:
	_queries[name] = query


func register_grid(name: String, grid: UniformSpatialGrid) -> void:
	_grids[name] = grid


func set_clock(clock: SimulationClock) -> void:
	_clock = clock


func get_clock() -> SimulationClock:
	return _clock


func get_queries() -> Dictionary:
	return _queries


func get_grids() -> Dictionary:
	return _grids


func get_world() -> EcsWorld:
	return _world


func get_scheduler() -> EcsScheduler:
	return _scheduler


## True when the visual panel actually exists. False in TELEMETRY mode, and false
## when the `inspector/` folder has been stripped from the build.
func has_panel() -> bool:
	return _panel != null and is_instance_valid(_panel)


func get_panel() -> Node:
	return _panel


## Shows or hides the panel, if there is one.
func set_panel_visible(value: bool) -> void:
	if has_panel():
		_panel.visible = value


## Prints the full text report. Works in any mode except OFF, with a panel and
## without.
func print_report() -> void:
	refresh_now()
	print(EcsReport.to_text(recorder, stats, _world, _findings))


## Prints a breakdown of the window's worst frame — the one that actually caused
## a hitch and that a live view cannot show.
func print_worst_frame() -> void:
	refresh_now()
	print(EcsReport.frame_to_text(recorder, stats.get_worst_frame_slot(), stats))


## Writes report.txt / report.json / frames.csv into [param directory]. Returns
## the number of files written.
func save_report(directory: String = "user://") -> int:
	refresh_now()
	var written: int = 0
	if EcsReport.save_text(directory.path_join("ecs_report.txt"), recorder, stats, _world, _findings):
		written += 1
	if EcsReport.save_json(directory.path_join("ecs_report.json"), recorder, stats, _world, _findings):
		written += 1
	if EcsReport.save_csv(directory.path_join("ecs_frames.csv"), recorder):
		written += 1
	return written


## Removes the panel and stops collecting.
func detach() -> void:
	if has_panel():
		_panel.queue_free()
	_panel = null
	_attached = false
	mode = Mode.OFF


func _build_extras() -> Dictionary:
	return {"clock": _clock, "queries": _queries, "grids": _grids}


## Resolves the panel next to this script, not by a path hard-coded into the
## project, so the add-on keeps working after it is copied anywhere. Loading by
## path (rather than by class name) is exactly what lets the whole `inspector/`
## folder be excluded from the export without breaking this file.
func _create_panel(parent: Node) -> void:
	var own_path: String = get_script().resource_path
	if own_path.is_empty():
		return
	var panel_path: String = own_path.get_base_dir().path_join(_PANEL_RELATIVE_PATH).simplify_path()
	if not ResourceLoader.exists(panel_path):
		# The interface is stripped from this build: silently degrade to
		# collection only.
		return
	var panel_script: Script = load(panel_path)
	if panel_script == null:
		return
	var panel: Node = panel_script.new()
	if panel == null:
		return
	_panel = panel
	parent.add_child(panel)
	if panel.has_method(&"bind"):
		panel.call(&"bind", self)
