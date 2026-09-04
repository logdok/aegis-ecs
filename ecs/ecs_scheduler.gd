class_name EcsScheduler
extends RefCounted

## Упорядоченный детерминированный конвейер систем со встроенным
## профилированием каждой отдельной системы.
##
## Планировщик держит ВСЁ «что за чем выполняется» в одном месте. Список систем
## задаётся один раз при сборке мира и больше не меняется; планировщик просто
## идёт по нему в том же порядке каждый кадр.
##
## [b]Порядок систем — это поведение, а не оформление кода.[/b] Перестановка
## двух строк регистрации меняет то, что происходит в игре: если система Б
## читает данные, которые система А пишет в этом же кадре, А обязана идти
## раньше. Относитесь к списку регистрации как к спецификации.
##
## [b]Профилирование[/b] — основной инструмент диагностики производительности
## прямо на устройстве: [method get_timing_usec] отдаёт время каждой системы в
## микросекундах за последний кадр, а [method get_average_timing_usec] —
## сглаженное значение, которое намного легче читать на живом HUD. Микросекунды,
## а не миллисекунды, выбраны намеренно: дешёвые системы укладываются в единицы
## микросекунд, и миллисекундный отчёт состоял бы из нулей.
##
## Само измерение стоит два вызова [method Time.get_ticks_usec] на систему за
## кадр. Это немного, но если нужно выжать последнее — выключите
## [member profiling_enabled], и цикл пойдёт вообще без замеров.

## Вес самого свежего замера в сглаженном времени. Меньше — стабильнее.
const AVERAGE_SMOOTHING: float = 0.1

var profiling_enabled: bool = true

var _systems: Array[EcsSystem] = []
var _timings_usec: PackedFloat32Array = PackedFloat32Array()
var _average_usec: PackedFloat32Array = PackedFloat32Array()
var _phase_allowed: PackedByteArray = PackedByteArray()
var _executed: PackedByteArray = PackedByteArray()
var _is_setup: bool = false
var _world: EcsWorld
var _context


## Регистрирует [param system] в конвейере и возвращает её же — порядок вызовов
## add_system() определяет порядок исполнения.
func add_system(system: EcsSystem, phase: int = 0) -> EcsSystem:
	if _is_setup:
		push_error("EcsScheduler: add_system() после setup_all() запрещён")
		return system
	if _systems.has(system):
		push_error("EcsScheduler: один и тот же объект системы зарегистрирован дважды")
		return system
	if not system._assign_phase(phase, get_instance_id()):
		return system
	_systems.append(system)
	_timings_usec.resize(_systems.size())
	_average_usec.resize(_systems.size())
	_phase_allowed.append(1)
	_executed.append(0)
	return system


## Вызывает [method EcsSystem.setup] у каждой зарегистрированной системы.
## Звать один раз, когда мир, все хранилища и весь список систем готовы.
func setup_all(world: EcsWorld, context) -> bool:
	if _is_setup:
		push_error("EcsScheduler: setup_all() уже был вызван")
		return false
	_world = world
	_context = context
	for system in _systems:
		system.setup(world, context)
	_is_setup = true
	return true


func teardown_all() -> void:
	if not _is_setup:
		return
	for index in range(_systems.size() - 1, -1, -1):
		_systems[index].teardown()
	_is_setup = false
	_world = null
	_context = null


## Выполняет ВСЕ системы за один кадр, строго в порядке регистрации.
##
## [param delta] передаётся системам как есть. Чтобы поставить симуляцию на
## паузу, передайте 0.0: системы, объявившие [member EcsSystem.requires_time],
## будут пропущены, а остальные (рендер, камера, HUD) продолжат работать — см.
## [method EcsSystem.execute].
func execute_all(delta: float) -> void:
	if not _is_setup:
		push_error("EcsScheduler: execute_all() до setup_all()")
		return
	begin_frame()
	var total: int = _systems.size()
	var time_stopped: bool = delta <= 0.0
	if profiling_enabled:
		for i in total:
			var system: EcsSystem = _systems[i]
			if not system.enabled or _phase_allowed[i] == 0:
				continue
			if time_stopped and system.requires_time:
				continue
			var started: int = Time.get_ticks_usec()
			system.execute(delta)
			_timings_usec[i] += float(Time.get_ticks_usec() - started)
			_executed[i] = 1
	else:
		for i in total:
			var system: EcsSystem = _systems[i]
			if not system.enabled or _phase_allowed[i] == 0:
				continue
			if time_stopped and system.requires_time:
				continue
			system.execute(delta)
			_executed[i] = 1


## Закрывает замеры предыдущего кадра и очищает покадровое состояние. Вызывайте
## один раз перед серией вызовов [method execute_phase]; [method execute_all]
## делает это сам.
##
## Времена НАКАПЛИВАЮТСЯ между двумя begin_frame(), поэтому кадр с фиксированным
## шагом, выполнивший фазу симуляции четыре раза, отчитается о суммарной
## стоимости этих четырёх суб-шагов — то есть о том, что реально попало в
## бюджет кадра. Сглаженное среднее сворачивается здесь, один раз за кадр, а не
## на каждом суб-шаге.
func begin_frame() -> void:
	if profiling_enabled:
		for i in _average_usec.size():
			_average_usec[i] += (_timings_usec[i] - _average_usec[i]) * AVERAGE_SMOOTHING
	_timings_usec.fill(0.0)
	_executed.fill(0)


## Выполняет одну фазу в порядке регистрации. Фазы — это фильтр и метаданные;
## планировщик никогда не сортирует системы автоматически.
func execute_phase(phase: int, delta: float) -> void:
	if not _is_setup:
		push_error("EcsScheduler: execute_phase() до setup_all()")
		return
	var time_stopped: bool = delta <= 0.0
	for i in _systems.size():
		var system: EcsSystem = _systems[i]
		if system.system_phase != phase or not system.enabled or _phase_allowed[i] == 0:
			continue
		if time_stopped and system.requires_time:
			continue
		if profiling_enabled:
			var started: int = Time.get_ticks_usec()
			system.execute(delta)
			_timings_usec[i] += float(Time.get_ticks_usec() - started)
		else:
			system.execute(delta)
		_executed[i] = 1


func set_system_enabled(index: int, value: bool) -> void:
	_systems[index].enabled = value
	if not value:
		_timings_usec[index] = 0.0
		_executed[index] = 0


func is_system_enabled(index: int) -> bool:
	return _systems[index].enabled


func set_phase_enabled(phase: int, value: bool) -> void:
	for index in _systems.size():
		if _systems[index].system_phase == phase:
			_phase_allowed[index] = 1 if value else 0
			if not value:
				_timings_usec[index] = 0.0
				_executed[index] = 0


func set_system_phase(index: int, phase: int) -> void:
	var phase_allowed: int = 1
	for other_index in _systems.size():
		if other_index != index and _systems[other_index].system_phase == phase:
			phase_allowed = _phase_allowed[other_index]
			break
	if not _systems[index]._assign_phase(phase, get_instance_id()):
		return
	_phase_allowed[index] = phase_allowed
	_timings_usec[index] = 0.0
	_executed[index] = 0


## Разрешена ли система [param index] к запуску своей ФАЗОЙ — в отличие от
## собственного выключателя [member EcsSystem.enabled].
##
## Инструментам нужно отличать одно от другого: «эта система выключена» и
## «выключена вся фаза, к которой она относится» выглядят в замерах одинаково,
## но означают совершенно разное, когда ищешь, почему что-то перестало
## происходить.
func is_phase_allowed(index: int) -> bool:
	return _phase_allowed[index] == 1


func is_phase_enabled(phase: int) -> bool:
	for index in _systems.size():
		if _systems[index].system_phase == phase and _phase_allowed[index] == 0:
			return false
	return true


func get_system_count() -> int:
	return _systems.size()


func get_system_name(index: int) -> String:
	return _systems[index].system_name


func get_system(index: int) -> EcsSystem:
	return _systems[index]


func get_system_phase(index: int) -> int:
	return _systems[index].system_phase


## Индекс первой системы с таким именем, либо -1. Холодный путь; удобно, чтобы
## переключить систему по имени из отладочной панели.
func find_system(name: String) -> int:
	for index in _systems.size():
		if _systems[index].system_name == name:
			return index
	return -1


func was_system_executed(index: int) -> bool:
	return _executed[index] == 1


## Время работы системы [param index] за последний кадр, в микросекундах.
## Пока [member profiling_enabled] выключено, значения не обновляются.
func get_timing_usec(index: int) -> float:
	return _timings_usec[index]


## Экспоненциально сглаженное время, в микросекундах. Намного стабильнее
## покадрового значения — именно его обычно и хочет показывать отладочный
## оверлей.
func get_average_timing_usec(index: int) -> float:
	return _average_usec[index]


func get_total_timing_usec() -> float:
	var total: float = 0.0
	for timing in _timings_usec:
		total += timing
	return total


func reset_profiling() -> void:
	_timings_usec.fill(0.0)
	_average_usec.fill(0.0)
	_executed.fill(0)


## Валидация на холодном пути — для инструментов сборки и тестов.
func validate_pipeline(world: EcsWorld, report_errors: bool = true) -> bool:
	var valid := true
	var previous_phase: int = -2_147_483_648
	for system in _systems:
		if system.system_name.is_empty() or system.system_name == "UnnamedSystem":
			valid = false
			if report_errors:
				push_error("EcsScheduler: у системы нет диагностического имени")
		if system.system_phase < previous_phase:
			valid = false
			if report_errors:
				push_error("EcsScheduler: фазы должны идти неубывающе в порядке регистрации")
		previous_phase = system.system_phase
		for type_id in system.read_component_types:
			valid = _validate_type(world, system, type_id, report_errors) and valid
		for type_id in system.write_component_types:
			valid = _validate_type(world, system, type_id, report_errors) and valid
		for type_id in system.structural_write_component_types:
			valid = _validate_type(world, system, type_id, report_errors) and valid
	return valid


## Консервативный анализ зависимостей для инструментов и будущих параллельных
## батчей. Текущий планировщик остаётся намеренно последовательным.
func systems_conflict(first_index: int, second_index: int) -> bool:
	var first: EcsSystem = _systems[first_index]
	var second: EcsSystem = _systems[second_index]
	if not first.access_metadata_complete or not second.access_metadata_complete:
		return true
	# Изменения жизненного цикла мира могут инвалидировать сырые id и любой
	# View, поэтому они конфликтуют с каждой системой независимо от объявлений
	# о компонентах.
	if first.writes_world_structure or second.writes_world_structure:
		return true
	if _intersects(first.write_component_types, second.read_component_types) \
			or _intersects(first.write_component_types, second.write_component_types) \
			or _intersects(first.write_component_types, second.structural_write_component_types) \
			or _intersects(second.write_component_types, first.read_component_types) \
			or _intersects(second.write_component_types, first.structural_write_component_types):
		return true
	if _structural_conflict(first.structural_write_component_types, second) \
			or _structural_conflict(second.structural_write_component_types, first):
		return true
	return false


func _validate_type(world: EcsWorld, system: EcsSystem, type_id: int, report_errors: bool) -> bool:
	if world.has_store(type_id):
		return true
	if report_errors:
		push_error("EcsScheduler: система %s ссылается на незарегистрированный тип %d" % [system.system_name, type_id])
	return false


func _structural_conflict(types: PackedInt32Array, system: EcsSystem) -> bool:
	return _intersects(types, system.read_component_types) \
		or _intersects(types, system.write_component_types) \
		or _intersects(types, system.structural_write_component_types)


func _intersects(first: PackedInt32Array, second: PackedInt32Array) -> bool:
	for value in first:
		if second.has(value):
			return true
	return false
