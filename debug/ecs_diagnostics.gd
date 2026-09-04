class_name EcsDiagnostics
extends RefCounted

## Читает числа за вас.
##
## Каждое правило здесь соответствует задокументированному, реальному сбою,
## который сам по себе не выдаёт никакого сообщения об ошибке: запрос, чей кэш
## не влучает никогда; очередь уничтожения, которая не спорожняется, потому что
## жнец стоит не там; пространственная сетка, размер ячейки которой превращает
## перестройку в основном в прогулку по пустоте. Каждое очевидно, когда знаешь,
## куда смотреть, и ни одно не очевидно, пока смотришь на стену микросекунд.
##
## Находка несёт важность, то, что было измерено, и что с этим делать.
##
## [codeblock]
## var diagnostics := EcsDiagnostics.new()
## for finding in diagnostics.inspect(recorder, stats, world):
##     print(finding.format())
## [/codeblock]
##
## Правила, которым нужны объекты, не принадлежащие миру — запросы, сетки,
## часы, — получают их через [param extras]; библиотека намеренно не держит их
## реестра.


## Одна находка.
class Finding extends RefCounted:
	enum Severity { INFO = 0, WARNING = 1, CRITICAL = 2 }

	var severity: int = Severity.INFO
	var source: String = ""
	var title: String = ""
	var detail: String = ""
	var hint: String = ""

	func _init(finding_severity: int, finding_source: String, finding_title: String,
			finding_detail: String, finding_hint: String = "") -> void:
		severity = finding_severity
		source = finding_source
		title = finding_title
		detail = finding_detail
		hint = finding_hint

	func severity_label() -> String:
		match severity:
			Severity.CRITICAL:
				return "CRITICAL"
			Severity.WARNING:
				return "WARNING"
		return "INFO"

	func format() -> String:
		var text: String = "[%s] %s: %s" % [severity_label(), source, title]
		if not detail.is_empty():
			text += "\n    " + detail
		if not hint.is_empty():
			text += "\n    -> " + hint
		return text


## Бюджет кадра, с которым сравнивается p95. 16600 мкс — это 60 Гц.
var frame_budget_usec: float = 16600.0

## Система, занимающая больше этой доли кадра, называется вслух — не как
## неисправность, а чтобы доминирующая стоимость никогда не была сюрпризом.
var dominant_share_percent: float = 40.0

## Отношение max/median, выше которого система считается источником рывков.
var volatility_warning: float = 5.0

## Минимальная доля избытка в медленных кадрах, начиная с которой о нестабильной
## системе сообщается.
var excess_share_warning: float = 15.0

## Заполненность мира, при которой выдаётся предупреждение о ёмкости.
var load_factor_warning: float = 0.85

## Заполненность хранилища, при которой выдаётся предупреждение.
var store_fill_warning: float = 0.90

## Отношение худшего кадра к медианному, выше которого о рывках сообщается.
var spike_ratio_warning: float = 2.0

# Темп перестроек запроса — это дельта между вызовами, поэтому предыдущее
# показание хранится здесь.
var _query_rebuilds: Dictionary = {}
var _query_frames: Dictionary = {}


## Выполняет все правила и возвращает находки, худшие первыми.
##
## [param extras] может содержать:
## [codeblock]
## {
##     "clock":   SimulationClock,
##     "queries": { "targets": EcsQuery, ... },
##     "grids":   { "enemies": UniformSpatialGrid, ... },
## }
## [/codeblock]
func inspect(recorder: EcsFrameRecorder, stats: EcsFrameStats, world: EcsWorld,
		extras: Dictionary = {}) -> Array:
	var findings: Array = []
	if world != null:
		_check_world(findings, world)
		_check_stores(findings, world)
	if recorder != null and stats != null and stats.is_analysed():
		_check_frame_budget(findings, stats)
		_check_systems(findings, recorder, stats)
		_check_destroy_queue(findings, stats)
	if extras.has("queries"):
		_check_queries(findings, extras["queries"], recorder)
	if extras.has("grids"):
		_check_grids(findings, extras["grids"])
	if extras.has("clock") and extras["clock"] != null:
		_check_clock(findings, extras["clock"])

	findings.sort_custom(func(a, b): return a.severity > b.severity)
	return findings


## Очищает запомненные счётчики перестроек запросов. Вызывайте после перезапуска
## уровня.
func reset() -> void:
	_query_rebuilds.clear()
	_query_frames.clear()


func _check_world(findings: Array, world: EcsWorld) -> void:
	var load_factor: float = world.get_load_factor()
	if load_factor >= 1.0:
		findings.append(Finding.new(Finding.Severity.CRITICAL, "World",
			"Entity capacity exhausted",
			"live %d of %d; create_entity() is returning -1" % [world.get_live_count(), world.capacity],
			"Raise the initial capacity, or register an EcsCapacityPolicySystem right after the reaper."))
	elif load_factor >= load_factor_warning:
		findings.append(Finding.new(Finding.Severity.WARNING, "World",
			"Entity capacity nearly full",
			"live %d of %d (%.0f%%)" % [world.get_live_count(), world.capacity, load_factor * 100.0],
			"Grow before it fills: EcsCapacityPolicySystem, or a larger initial capacity."))


func _check_stores(findings: Array, world: EcsWorld) -> void:
	for index in world.get_store_count():
		var store: EcsComponentStore = world.get_store_at(index)
		var capacity: int = store.get_capacity()
		if capacity <= 0:
			continue
		var fill: float = float(store.count) / float(capacity)
		if fill >= 1.0:
			findings.append(Finding.new(Finding.Severity.CRITICAL, "Store",
				"'%s' is full" % store.get_debug_name(),
				"%d of %d slots used; the next attach() will return -1" % [store.count, capacity],
				"Grow the world, or check whether this store is leaking components."))
		elif fill >= store_fill_warning:
			findings.append(Finding.new(Finding.Severity.WARNING, "Store",
				"'%s' is nearly full" % store.get_debug_name(),
				"%d of %d slots used (%.0f%%)" % [store.count, capacity, fill * 100.0], ""))
		if store.change_log_overflowed:
			findings.append(Finding.new(Finding.Severity.INFO, "Store",
				"'%s' change log overflowed" % store.get_debug_name(),
				"clear() or world.reset() wiped the store, so individual removals were not logged",
				"Expected after a restart; call clear_change_log() to reset the flag."))


func _check_frame_budget(findings: Array, stats: EcsFrameStats) -> void:
	var p95: float = stats.get_frame_p95_usec()
	if p95 > frame_budget_usec:
		findings.append(Finding.new(Finding.Severity.CRITICAL, "Frame",
			"ECS exceeds the frame budget",
			"p95 %.2f ms against a %.2f ms budget (median %.2f ms)"
				% [p95 / 1000.0, frame_budget_usec / 1000.0, stats.get_frame_median_usec() / 1000.0],
			"Most frames are already over budget before rendering. Start with the top spike contributor."))

	var ratio: float = stats.get_spike_ratio()
	if ratio >= spike_ratio_warning and stats.get_spike_frame_count() > 0:
		findings.append(Finding.new(Finding.Severity.WARNING, "Frame",
			"Uneven frame cost",
			"worst frame is %.1fx the median (%d of %d frames ran long)"
				% [ratio, stats.get_spike_frame_count(), stats.get_frame_count()],
			"An uneven frame is felt as stutter even when the average looks fine."))


func _check_systems(findings: Array, recorder: EcsFrameRecorder, stats: EcsFrameStats) -> void:
	for index in stats.get_system_count():
		var share: float = stats.get_system_share_percent(index)
		var volatility: float = stats.get_system_volatility(index)
		var excess_share: float = stats.get_system_excess_share(index)

		if share >= dominant_share_percent:
			findings.append(Finding.new(Finding.Severity.INFO, "System",
				"'%s' dominates the frame" % recorder.get_system_name(index),
				"%.0f%% of ECS time, median %d us (stable: %.1fx)"
					% [share, int(stats.get_system_median_usec(index)), volatility],
				"Steady cost, not a stutter source. Optimise it to lower the baseline."))

		if volatility >= volatility_warning and excess_share >= excess_share_warning:
			findings.append(Finding.new(Finding.Severity.WARNING, "System",
				"'%s' causes slow frames" % recorder.get_system_name(index),
				"median %d us but peaks at %d us (%.0fx); accounts for %.0f%% of the excess in slow frames"
					% [int(stats.get_system_median_usec(index)), int(stats.get_system_max_usec(index)),
					   volatility, excess_share],
				"A system that is usually cheap and occasionally expensive is what stutter feels like. "
				+ "Look for work that happens in bursts rather than every frame."))


func _check_destroy_queue(findings: Array, stats: EcsFrameStats) -> void:
	var peak: int = stats.get_peak_pending_destroy()
	if peak > 0:
		findings.append(Finding.new(Finding.Severity.CRITICAL, "Lifecycle",
			"Destroy queue is not being drained",
			"up to %d entities were still queued at the end of a frame" % peak,
			"flush_destroy_queue() is not running, or it runs before the systems that queue destruction. "
			+ "Register an EcsReaperSystem as the LAST system."))


func _check_queries(findings: Array, queries: Dictionary, recorder: EcsFrameRecorder) -> void:
	var frames_now: int = recorder.get_frames_seen() if recorder != null else 0
	for name in queries:
		var query: EcsQuery = queries[name]
		if query == null:
			continue
		if query.is_truncated():
			findings.append(Finding.new(Finding.Severity.WARNING, "Query",
				"'%s' result is truncated" % name,
				"more entities matched than the %d-entry buffer holds" % query.get_result_capacity(),
				"Raise maximum_results, or narrow the query."))

		var rebuilds_now: int = query.get_rebuild_count()
		if _query_rebuilds.has(name):
			var rebuild_delta: int = rebuilds_now - int(_query_rebuilds[name])
			var frame_delta: int = frames_now - int(_query_frames[name])
			if frame_delta >= 30 and rebuild_delta >= frame_delta:
				findings.append(Finding.new(Finding.Severity.WARNING, "Query",
					"'%s' rebuilds every frame" % name,
					"%d rebuilds over %d frames - the cache never hits" % [rebuild_delta, frame_delta],
					"Some participating store changes membership every frame. Drop the volatile "
					+ "component from the query, or use EcsView / a direct loop instead."))
		_query_rebuilds[name] = rebuilds_now
		_query_frames[name] = frames_now


func _check_grids(findings: Array, grids: Dictionary) -> void:
	for name in grids:
		var grid: UniformSpatialGrid = grids[name]
		if grid == null:
			continue
		var cells: int = grid.get_cell_count()
		var entries: int = grid.get_entry_count()
		if cells <= 0:
			continue
		# Цена перестройки — O(записи + ячейки): сетка, у которой ячеек намного больше,
		# чем объектов, тратит большую часть перестройки на обход пустоты.
		if entries > 0 and cells > entries * 8:
			findings.append(Finding.new(Finding.Severity.WARNING, "Grid",
				"'%s' has far more cells than objects" % name,
				"%d cells for %d entries - the rebuild is mostly iterating empty cells" % [cells, entries],
				"Increase cell_size, or use UniformSpatialGrid.suggest_cell_size(). "
				+ "Populations of different density want separate grids."))
		elif entries > 0 and entries > cells * 32:
			findings.append(Finding.new(Finding.Severity.WARNING, "Grid",
				"'%s' cells are overcrowded" % name,
				"%d entries across only %d cells (~%d per cell)" % [entries, cells, entries / cells],
				"Queries have to distance-check too many candidates. Decrease cell_size."))
		if not grid.is_flat() and grid.get_dimensions().y <= 2:
			findings.append(Finding.new(Finding.Severity.INFO, "Grid",
				"'%s' is 3D but almost flat" % name,
				"only %d vertical layers" % grid.get_dimensions().y,
				"If the world is a plane, pass vertical_extent = 0.0 for flat mode and cut the cell count."))


func _check_clock(findings: Array, clock: SimulationClock) -> void:
	if clock.dropped_substeps > 0:
		findings.append(Finding.new(Finding.Severity.WARNING, "Clock",
			"Simulation cannot keep up",
			"%d substeps discarded; requested time_scale %.1f" % [clock.dropped_substeps, clock.time_scale],
			"The machine is not producing the requested speed-up. Lower time_scale, raise fixed_step, "
			+ "or make the simulation cheaper."))
	elif clock.is_saturated():
		findings.append(Finding.new(Finding.Severity.INFO, "Clock",
			"Substep cap reached",
			"the frame used all %d allowed substeps" % clock.max_substeps, ""))
