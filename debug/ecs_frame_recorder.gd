class_name EcsFrameRecorder
extends RefCounted

## Записывает, во что обошёлся каждый кадр, в разрезе по системам, в кольцевой
## буфер фиксированного размера.
##
## [b]Это и есть самая полезная часть.[/b] Живой показ текущего кадра мельтешит
## слишком быстро, чтобы его читать, и показывает тот кадр, на который вы
## случайно посмотрели; интересный кадр почти всегда уже прошёл. Хранение окна
## истории превращает «цифры скачут» в «вот кадр, который стоил втрое больше
## медианы, и вот на что он потратил лишнее».
##
## Не содержит нод и никогда не трогает дерево сцены, поэтому работает headless —
## в CI, в QA-сборке или по команде из консоли — с интерфейсом и без него. После
## [method configure] не выполняет ни одной аллокации, поэтому его не жалко
## оставить включённым в релизной сборке.
##
## [codeblock]
## var recorder := EcsFrameRecorder.new()
## recorder.configure(scheduler, world)          # один раз
##
## func _process(delta: float) -> void:
##     scheduler.execute_all(delta)
##     recorder.capture()                        # последней строкой кадра
## [/codeblock]
##
## Читать окно обратно — через [EcsFrameStats] (агрегаты, атрибуция всплесков)
## или [EcsReport] (текст/JSON). См. также [EcsInspector], который связывает всё
## это одним вызовом.

## Сколько кадров хранится по умолчанию: 4 секунды при 60 Гц — достаточно, чтобы
## в окно попал рывок, и всё ещё дёшево (240 кадров x 20 систем x 4 байта ~ 19 КБ).
const DEFAULT_FRAME_CAPACITY: int = 240

## Что произошло с системой за один кадр.
enum Status {
	EXECUTED = 0,
	## Пропущена, потому что система объявила `requires_time`, а шаг был нулевым.
	SKIPPED_PAUSED = 1,
	## Пропущена, потому что выключена сама система.
	DISABLED = 2,
	## Пропущена, потому что выключена вся её фаза.
	PHASE_OFF = 3,
}

var frame_capacity: int = 0
var system_count: int = 0

var _scheduler: EcsScheduler
var _world: EcsWorld
var _names: PackedStringArray = PackedStringArray()
var _phases: PackedInt32Array = PackedInt32Array()
var _requires_time: PackedByteArray = PackedByteArray()

# Кольцевые буферы. Посистемные — плоские: индекс = slot * system_count + i.
var _timings: PackedFloat32Array = PackedFloat32Array()
var _status: PackedByteArray = PackedByteArray()
var _frame_total: PackedFloat32Array = PackedFloat32Array()
var _frame_wall: PackedFloat32Array = PackedFloat32Array()
var _frame_substeps: PackedInt32Array = PackedInt32Array()
var _frame_live: PackedInt32Array = PackedInt32Array()
var _frame_pending: PackedInt32Array = PackedInt32Array()
var _frame_capacity_at: PackedInt32Array = PackedInt32Array()
var _frame_structural: PackedInt32Array = PackedInt32Array()
var _frame_id: PackedInt32Array = PackedInt32Array()

var _write: int = 0
var _filled: int = 0
var _frames_seen: int = 0
var _last_structural: int = 0
var _configured: bool = false

## Сколько занял последний [method capture], в микросекундах. Наблюдатель,
## измеряющий сам себя: если эта величина станет заметной на фоне кадра, значит
## окно слишком велико или capture вызывается слишком часто.
var last_capture_usec: float = 0.0


## Привязывается к конвейеру и преаллоцирует все буферы. Вызывается один раз,
## после [method EcsScheduler.setup_all].
func configure(scheduler: EcsScheduler, world: EcsWorld, frames: int = DEFAULT_FRAME_CAPACITY) -> bool:
	if scheduler == null or world == null:
		push_error("EcsFrameRecorder: нужны и планировщик, и мир")
		return false
	_scheduler = scheduler
	_world = world
	system_count = scheduler.get_system_count()
	frame_capacity = maxi(frames, 2)

	_names.resize(system_count)
	_phases.resize(system_count)
	_requires_time.resize(system_count)
	for i in system_count:
		_names[i] = scheduler.get_system_name(i)
		_phases[i] = scheduler.get_system_phase(i)
		_requires_time[i] = 1 if scheduler.get_system(i).requires_time else 0

	var cells: int = frame_capacity * maxi(system_count, 1)
	_timings.resize(cells)
	_status.resize(cells)
	_frame_total.resize(frame_capacity)
	_frame_wall.resize(frame_capacity)
	_frame_substeps.resize(frame_capacity)
	_frame_live.resize(frame_capacity)
	_frame_pending.resize(frame_capacity)
	_frame_capacity_at.resize(frame_capacity)
	_frame_structural.resize(frame_capacity)
	_frame_id.resize(frame_capacity)

	_write = 0
	_filled = 0
	_frames_seen = 0
	_last_structural = world.structural_version
	_configured = true
	return true


## Записывает только что закончившийся кадр. Вызывайте последним действием
## кадра, после того как отработали все фазы.
##
## [param substeps] — сколько раз за этот кадр выполнилась фаза симуляции;
## передавайте [method SimulationClock.get_last_substeps] при фиксированном
## шаге, иначе оставьте 1. Замеры планировщика накапливаются между вызовами
## `begin_frame()`, поэтому без этого числа кадр с фиксированным шагом выглядит
## в N раз дороже на систему, чем он есть.
##
## [param wall_frame_usec] — длительность всего отрисованного кадра, если она
## известна. Разница между ней и записанной суммой ECS — это всё, что вне
## планировщика: рендер, физика, прочие скрипты. Ровно то разделение, которое
## нужно, чтобы понять, чья это проблема, когда кадр просел.
func capture(substeps: int = 1, wall_frame_usec: float = 0.0) -> void:
	if not _configured:
		return
	var started: int = Time.get_ticks_usec()

	var slot: int = _write
	var base: int = slot * system_count
	var timings: PackedFloat32Array = _timings
	var status: PackedByteArray = _status
	var scheduler: EcsScheduler = _scheduler
	var total: float = 0.0

	for i in system_count:
		var value: float = scheduler.get_timing_usec(i)
		timings[base + i] = value
		total += value
		if scheduler.was_system_executed(i):
			status[base + i] = Status.EXECUTED
		elif not scheduler.is_system_enabled(i):
			status[base + i] = Status.DISABLED
		elif not scheduler.is_phase_allowed(i):
			status[base + i] = Status.PHASE_OFF
		else:
			status[base + i] = Status.SKIPPED_PAUSED

	var world: EcsWorld = _world
	var structural: int = world.structural_version
	_frame_total[slot] = total
	_frame_wall[slot] = wall_frame_usec
	_frame_substeps[slot] = maxi(substeps, 1)
	_frame_live[slot] = world.get_live_count()
	_frame_pending[slot] = world.get_pending_destroy_count()
	_frame_capacity_at[slot] = world.capacity
	_frame_structural[slot] = structural - _last_structural
	_frame_id[slot] = _frames_seen
	_last_structural = structural

	_write = (_write + 1) % frame_capacity
	_filled = mini(_filled + 1, frame_capacity)
	_frames_seen += 1
	last_capture_usec = float(Time.get_ticks_usec() - started)


## Забывает окно без переаллокации. Используйте после перезапуска уровня, чтобы
## кадры прошлого забега не искажали статистику.
func clear() -> void:
	_write = 0
	_filled = 0
	_frames_seen = 0
	if _world != null:
		_last_structural = _world.structural_version


func is_configured() -> bool:
	return _configured


## Сколько кадров сейчас хранится, от 0 до [member frame_capacity].
func get_frame_count() -> int:
	return _filled


## Сколько кадров записано всего, включая уже перезаписанные.
func get_frames_seen() -> int:
	return _frames_seen


## Слот кольца с самым свежим записанным кадром, либо -1, если окно пусто.
func get_newest_slot() -> int:
	if _filled == 0:
		return -1
	return (_write - 1 + frame_capacity) % frame_capacity


## Слот кольца с кадром [param age]-м с конца (0 — самый свежий), либо -1, если
## этот кадр уже вытеснен.
func get_slot_from_newest(age: int) -> int:
	if age < 0 or age >= _filled:
		return -1
	return (_write - 1 - age + frame_capacity) % frame_capacity


## Слот кольца с [param index]-м по старшинству кадром — для обхода окна в
## хронологическом порядке.
func get_slot_in_order(index: int) -> int:
	if index < 0 or index >= _filled:
		return -1
	var oldest: int = (_write - _filled + frame_capacity) % frame_capacity
	return (oldest + index) % frame_capacity


# --- чтение покадровых величин -------------------------------------------------

func get_frame_total_usec(slot: int) -> float:
	return _frame_total[slot]


func get_frame_wall_usec(slot: int) -> float:
	return _frame_wall[slot]


func get_frame_substeps(slot: int) -> int:
	return _frame_substeps[slot]


func get_frame_live_count(slot: int) -> int:
	return _frame_live[slot]


func get_frame_pending_destroy(slot: int) -> int:
	return _frame_pending[slot]


func get_frame_world_capacity(slot: int) -> int:
	return _frame_capacity_at[slot]


## Насколько за этот кадр продвинулся `world.structural_version` — дешёвая мера
## того, сколько реально было создания, уничтожения и присоединения компонентов.
func get_frame_structural_delta(slot: int) -> int:
	return _frame_structural[slot]


## Монотонный номер кадра, устойчивый даже после переиспользования слота.
func get_frame_id(slot: int) -> int:
	return _frame_id[slot]


# --- чтение посистемных величин ------------------------------------------------

func get_system_name(index: int) -> String:
	return _names[index]


func get_system_phase(index: int) -> int:
	return _phases[index]


func system_requires_time(index: int) -> bool:
	return _requires_time[index] == 1


func get_timing_usec(slot: int, system_index: int) -> float:
	return _timings[slot * system_count + system_index]


func get_status(slot: int, system_index: int) -> int:
	return _status[slot * system_count + system_index]


## Плоский буфер замеров — для потребителя, который хочет обойти окно без
## вызова метода на каждую ячейку. Индексируется как
## `slot * system_count + system_index`. Только для чтения.
##
## [EcsFrameStats] использует именно его, а не [method get_timing_usec]: на
## нескольких тысячах ячеек вызов метода перевешивает всё остальное, что делает
## анализ.
func get_timings_unsafe() -> PackedFloat32Array:
	return _timings


## Плоский буфер статусов, индексируется так же, как [method get_timings_unsafe]. Только для чтения.
func get_status_unsafe() -> PackedByteArray:
	return _status


## Слот кольца с самым старым хранимым кадром, либо -1, если окно пусто. С ним
## потребитель может обойти окно арифметически, не вызывая
## [method get_slot_in_order] на каждый кадр.
func get_oldest_slot() -> int:
	if _filled == 0:
		return -1
	return (_write - _filled + frame_capacity) % frame_capacity


## Оценка памяти, занятой кольцевым буфером, в байтах.
func get_memory_usage() -> int:
	return _timings.size() * 4 + _status.size() + frame_capacity * 30
