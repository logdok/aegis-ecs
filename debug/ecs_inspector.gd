class_name EcsInspector
extends RefCounted

## Один вызов, который связывает воедино запись, статистику, диагностику и
## (по желанию) визуальную панель.
##
## [codeblock]
## var inspector := EcsInspector.attach(scheduler, world, {
##     "mode": EcsInspector.Mode.DEV,
##     "parent": $DebugLayer,          # уберите — будет сбор без интерфейса
##     "clock": simulation_clock,
##     "grids": { "enemies": enemy_grid },
##     "queries": { "targets": target_query },
## })
##
## func _process(delta: float) -> void:
##     scheduler.execute_all(delta)
##     inspector.capture()             # последней строкой кадра
## [/codeblock]
##
## [b]Режимы.[/b] Сбор достаточно дёшев, чтобы отгружать его в релизе;
## интерфейс нужен не всегда:
##
## [codeblock]
## Mode.OFF        не работает ничего
## Mode.TELEMETRY  запись + диагностика, без интерфейса  <- безопасно в релизе
## Mode.INSPECTOR  + панель, только просмотр
## Mode.DEV        + управление, меняющее симуляцию
## [/codeblock]
##
## [b]Интерфейс можно убрать полностью.[/b] Удалите `inspector/` или исключите
## его из пресета экспорта — и этот класс продолжит работать без панели: он
## разрешает её через [method load] по пути, а не по имени класса, поэтому
## отсутствующий файл — это null, а не ошибка разбора, которая утащит за собой
## всю игру.
##
## Всё, что нужно панели помимо мира — запросы, сетки, часы, ваши собственные
## счётчики — живёт вне библиотеки, поэтому передаётся сюда, а не разыскивается.
## Ядро намеренно не держит их реестра.

enum Mode {
	OFF = 0,
	## Запись и диагностика, без интерфейса. Достаточно дёшево для релизной сборки.
	TELEMETRY = 1,
	## Добавить панель, только просмотр.
	INSPECTOR = 2,
	## Добавить управление, меняющее симуляцию (выключение систем, пошаговый режим).
	DEV = 3,
}

const _PANEL_RELATIVE_PATH: String = "../inspector/ecs_inspector_panel.gd"

var mode: int = Mode.TELEMETRY

## Как часто пересчитываются агрегаты, в герцах.
##
## Намеренно реже, чем отрисовка: медиана по сотням кадров почти не сдвигается
## за десятую долю секунды, поэтому пересчитывать её чаще — не купить ничего и
## потратить реальное время. Запись при этом идёт каждый кадр: не теряется
## ничего, лениво обновляется только сводка.
var stats_refresh_hz: float = 2.0

## Как часто выполняется диагностика, в герцах. Ещё реже: находки меняются
## медленно, а некоторым правилам нужен зазор между замерами, чтобы измерить темп.
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


## Собирает инспектор и, если режим и родительская нода позволяют, панель.
## Всегда возвращает объект — никогда null — поэтому вызывающему коду не нужны
## ветвления.
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


## Записывает только что закончившийся кадр. Вызывайте один раз, последним
## действием кадра, после того как отработали все фазы.
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


## Принудительно и немедленно пересчитывает агрегаты и диагностику, игнорируя
## частоты обновления. Используйте перед печатью отчёта по требованию.
func refresh_now() -> void:
	if not _attached:
		return
	stats.analyse(recorder)
	_findings = diagnostics.inspect(recorder, stats, _world, _build_extras())


## Находки диагностики последнего прогона, худшие первыми.
func get_findings() -> Array:
	return _findings


## Регистрирует группу счётчиков приложения, показываемых вверху панели.
##
## Библиотека ничего не знает о вашей игре, поэтому не может сама показать
## «живых врагов» или «здоровье ядра». [param provider] возвращает строки как
## `[[подпись, значение], ...]`; значения могут быть любыми, они приводятся к
## тексту.
##
## Он вызывается с частотой обновления панели, а не каждый кадр, поэтому даже
## дорогой расчёт внутри него не касается бюджета кадра.
##
## [codeblock]
## inspector.add_counter_section("Популяция", func() -> Array:
##     return [
##         ["Активных", "%d / %d" % [my_store.count, my_target]],
##         ["Всего за забег", my_total],
##     ])
## [/codeblock]
func add_counter_section(title: String, provider: Callable) -> void:
	if not provider.is_valid():
		push_error("EcsInspector: у секции счётчиков «%s» недействительный провайдер" % title)
		return
	_counter_sections.append({"title": title, "provider": provider})


func get_counter_section_count() -> int:
	return _counter_sections.size()


func get_counter_section_title(index: int) -> String:
	return _counter_sections[index]["title"]


## Вычисляет одну секцию. Возвращает строки как `[[подпись, значение], ...]`.
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


## True, когда визуальная панель действительно существует. False в режиме
## TELEMETRY и false, когда папка `inspector/` вырезана из сборки.
func has_panel() -> bool:
	return _panel != null and is_instance_valid(_panel)


func get_panel() -> Node:
	return _panel


## Показывает или скрывает панель, если она есть.
func set_panel_visible(value: bool) -> void:
	if has_panel():
		_panel.visible = value


## Печатает полный текстовый отчёт. Работает в любом режиме, кроме OFF, с
## панелью и без неё.
func print_report() -> void:
	refresh_now()
	print(EcsReport.to_text(recorder, stats, _world, _findings))


## Печатает разбор самого худшего кадра окна — того, который реально дал рывок
## и который живой показ показать не в состоянии.
func print_worst_frame() -> void:
	refresh_now()
	print(EcsReport.frame_to_text(recorder, stats.get_worst_frame_slot(), stats))


## Записывает report.txt / report.json / frames.csv в [param directory].
## Возвращает число записанных файлов.
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


## Убирает панель и прекращает сбор.
func detach() -> void:
	if has_panel():
		_panel.queue_free()
	_panel = null
	_attached = false
	mode = Mode.OFF


func _build_extras() -> Dictionary:
	return {"clock": _clock, "queries": _queries, "grids": _grids}


## Разрешает панель рядом с этим скриптом, а не по жёстко прописанному пути в
## проекте, поэтому аддон продолжает работать после копирования куда угодно.
## Загрузка по пути (а не по имени класса) — это ровно то, что позволяет
## исключить всю папку `inspector/` из экспорта, не сломав этот файл.
func _create_panel(parent: Node) -> void:
	var own_path: String = get_script().resource_path
	if own_path.is_empty():
		return
	var panel_path: String = own_path.get_base_dir().path_join(_PANEL_RELATIVE_PATH).simplify_path()
	if not ResourceLoader.exists(panel_path):
		# Интерфейс вырезан из этой сборки: молча снижаемся до одного лишь сбора.
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
