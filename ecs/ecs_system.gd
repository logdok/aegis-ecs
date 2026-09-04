class_name EcsSystem
extends RefCounted

## Абстрактная единица логики симуляции.
##
## В ECS система — это чистая логика без собственных игровых данных. Система НЕ
## хранит принадлежащее миру состояние в своих полях (никаких «списков всех
## врагов»); вместо этого она каждый кадр заново читает и пишет хранилища
## компонентов. Это и отличает систему от обычного игрового объекта: система —
## по сути оформленная в класс функция «что сделать с этими данными», а не
## сущность со своей собственной жизнью.
##
## Системы выполняются [EcsScheduler] в ФИКСИРОВАННОМ порядке, заданном явно
## при регистрации. Этот порядок сам по себе является частью поведения игры
## (классический пример: индекс для поиска соседей должен перестраиваться ПОСЛЕ
## того, как объекты сдвинулись, но ДО того, как по нему кто-то будет искать).
##
## [b]Про параметр `context`[/b] в [method setup]: он намеренно не типизирован.
## Библиотека ничего не знает о вашей игре, поэтому передаёт объект-контекст как
## есть — обычно это ваш собственный класс со ссылками на все хранилища
## компонентов, конфигурацию и общее состояние. Присвойте его типизированному
## полю в своей системе:
## [codeblock]
## var _context: MyContext
##
## func setup(_world: EcsWorld, context) -> void:
##     _context = context
## [/codeblock]

## Имя системы. Показывается в профилировании ([EcsScheduler]), поэтому
## задавайте его в `_init()` наследника — иначе все системы в отчёте будут
## называться одинаково.
var system_name: String = "UnnamedSystem"

## Необязательная группировка. Планировщик никогда не переупорядочивает
## системы: фаза используется для выборочного исполнения, диагностики и будущих
## инструментов планирования.
var system_phase: int:
	get:
		return _system_phase
	set(value):
		if _phase_locked:
			push_error("EcsSystem(%s): фазу можно менять только через EcsScheduler" % system_name)
			return
		_system_phase = value

## Runtime-выключатель. Отключённая система сохраняет свой стабильный индекс в
## планировщике и показывает нулевое время за пропущенные кадры.
var enabled: bool = true

## Объявляет, что система ничего не делает, когда время не идёт.
##
## Пауза в этой библиотеке — это шаг нулевой длины, а не пропущенный кадр,
## чтобы рендер и прочие независимые от времени системы продолжали работать.
## Исторически каждая зависящая от времени система обязана была начинаться с
## `if delta <= 0.0: return`, и забытая строка была тихим багом.
##
## Вместо этого выставьте здесь `true` в `_init()`. Тогда планировщик пропустит
## вызов целиком, пока `delta <= 0.0` — это и безопаснее, и чуть быстрее
## раннего возврата. Оставьте `false` для систем, которые обязаны работать и на
## паузе: рендер, камера, ввод, выгрузка HUD.
var requires_time: bool = false

## Необязательное описание доступа. Оно не добавляет проверок в горячий путь и
## не меняет порядок исполнения; инструменты используют его, чтобы
## валидировать View и определять, какие системы можно было бы безопасно
## распараллелить в будущем планировщике.
var read_component_types: PackedInt32Array = PackedInt32Array()
var write_component_types: PackedInt32Array = PackedInt32Array()
var structural_write_component_types: PackedInt32Array = PackedInt32Array()
var writes_world_structure: bool = false
var access_metadata_complete: bool = false

var _system_phase: int = 0
var _phase_locked: bool = false
var _scheduler_owner_id: int = 0


## Вызывается один раз, после того как КАЖДОЕ хранилище компонентов
## зарегистрировано в мире и весь конвейер систем собран — то есть система
## может смело сохранить ссылку на [param _context] (или на конкретные
## хранилища из него), зная, что они уже существуют и проинициализированы.
##
## Кеширование ссылок на хранилища здесь — правильная практика, а не нарушение
## принципа «системы не хранят данные»: кешируется ССЫЛКА на существующее
## хранилище, а не копия данных.
func setup(_world: EcsWorld, _context) -> void:
	pass


## Вызывается в обратном порядке регистрации из EcsScheduler.teardown_all().
func teardown() -> void:
	pass


## Вызывается один раз за кадр, в порядке, заданном [EcsScheduler].
## [param _delta] — шаг симуляции в секундах.
##
## [b]Соглашение о паузе[/b]: пауза реализуется передачей нулевого шага, а не
## пропуском вызова, чтобы рендер и прочие не зависящие от времени системы
## продолжали работать. Выставьте [member requires_time] в `true`, и
## планировщик сам пропустит эту систему, пока шаг нулевой.
func execute(_delta: float) -> void:
	pass


func declare_read(component_type_id: int) -> EcsSystem:
	_append_unique(read_component_types, component_type_id)
	return self


func declare_write(component_type_id: int) -> EcsSystem:
	_append_unique(write_component_types, component_type_id)
	return self


func declare_structural_write(component_type_id: int) -> EcsSystem:
	_append_unique(structural_write_component_types, component_type_id)
	return self


func has_declared_access(component_type_id: int) -> bool:
	return read_component_types.has(component_type_id) \
		or write_component_types.has(component_type_id) \
		or structural_write_component_types.has(component_type_id)


func complete_access_metadata() -> EcsSystem:
	access_metadata_complete = true
	return self


## Холодный хук только для планировщика. Экземпляр системы принадлежит одному
## планировщику; общий экземпляр позволил бы одному планировщику менять
## состояние фазы за спиной другого.
func _assign_phase(value: int, scheduler_owner_id: int) -> bool:
	if _scheduler_owner_id != 0 and _scheduler_owner_id != scheduler_owner_id:
		push_error("EcsSystem(%s): один экземпляр нельзя регистрировать в двух планировщиках" % system_name)
		return false
	_scheduler_owner_id = scheduler_owner_id
	_system_phase = value
	_phase_locked = true
	return true


func _append_unique(values: PackedInt32Array, value: int) -> void:
	if not values.has(value):
		values.append(value)
