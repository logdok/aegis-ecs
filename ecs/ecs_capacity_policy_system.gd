class_name EcsCapacityPolicySystem
extends EcsSystem

## Растит мир ДО того, как в нём закончатся идентификаторы сущностей.
##
## [method EcsWorld.create_entity] возвращает -1, когда мир заполнен, а
## [method EcsWorld.reserve_capacity] — это явный аллоцирующий барьер, который
## нельзя выполнять посреди обхода систем. Такое сочетание нормально, пока
## население предсказуемо, но симуляция со взрывным ростом — делящаяся культура
## клеток, спавнер волн, цепная реакция — способна удвоить население за
## секунды и начать тихо терять споны.
##
## Эта система проверяет коэффициент заполнения раз в
## [member check_interval_frames] кадров и растит мир, как только он переходит
## порог [member grow_threshold] — то есть рост происходит, пока место ещё
## есть, а не после того, как споны уже потерялись.
##
## [codeblock]
## var policy := EcsCapacityPolicySystem.new(world)
## policy.grow_threshold = 0.8
## policy.growth_factor = 1.5
## policy.maximum_capacity = 200_000
## policy.on_capacity_grown = _resize_my_render_buffers
## scheduler.add_system(EcsReaperSystem.new(world))
## scheduler.add_system(policy)                       # сразу после жнеца
## [/codeblock]
##
## [b]Регистрируйте её сразу после жнеца[/b] или на другой явной границе фаз.
## Рост переаллоцирует все буферы мира и хранилищ, поэтому ни одна система не
## должна удерживать плотный слот или закешированный псевдоним массива через
## этот вызов.
##
## Библиотека умеет увеличить только СВОИ буферы. Всё, что игра выделила
## параллельно — `MultiMesh`, батчи физики, сетевые массивы, — увеличивает ваш
## колбек [member on_capacity_grown].

## Расти, когда эта доля мира занята живыми сущностями.
var grow_threshold: float = 0.85

## Новая ёмкость — старая, умноженная на это число. 1.5 делает переаллокацию
## редкой, не удваивая память на каждом шаге.
var growth_factor: float = 1.5

## Жёсткий потолок. 0 означает «без ограничения, кроме того, что позволяет
## раскладка handle».
var maximum_capacity: int = 0

## Как часто выполняется проверка. Проверять каждый кадр бессмысленно:
## коэффициент заполнения не может заметно сдвинуться за один кадр, а рост —
## событие редкое.
var check_interval_frames: int = 30

## Вызывается как `callable.call(previous_capacity, new_capacity)` после
## успешного роста, чтобы игра увеличила буферы, о которых библиотека не знает.
var on_capacity_grown: Callable = Callable()

## Диагностика.
var growth_count: int = 0
var last_growth_capacity: int = 0

var _world: EcsWorld
var _frames_since_check: int = 0


func _init(world: EcsWorld = null, system_display_name: String = "CapacityPolicy") -> void:
	system_name = system_display_name
	writes_world_structure = true
	complete_access_metadata()
	_world = world


func setup(world: EcsWorld, context) -> void:
	if _world == null:
		_world = world
	if _world == null and context != null and context.get(&"world") != null:
		_world = context.get(&"world")
	if _world == null:
		push_error("EcsCapacityPolicySystem: нет мира — передайте его в _init() или в setup()")


func execute(_delta: float) -> void:
	if _world == null:
		return
	_frames_since_check += 1
	if _frames_since_check < check_interval_frames:
		return
	_frames_since_check = 0
	if _world.get_load_factor() < grow_threshold:
		return
	grow_now()


## Немедленно выполняет проверку роста, игнорируя интервал. Используйте прямо
## перед всплеском, размер которого уже известен заранее.
func grow_now() -> bool:
	if _world == null:
		return false
	var previous_capacity: int = _world.capacity
	var target: int = int(ceil(float(previous_capacity) * maxf(growth_factor, 1.01)))
	if target <= previous_capacity:
		target = previous_capacity + 1
	if maximum_capacity > 0:
		target = mini(target, maximum_capacity)
	if target <= previous_capacity:
		return false
	if not _world.reserve_capacity(target):
		return false
	growth_count += 1
	last_growth_capacity = target
	if on_capacity_grown.is_valid():
		on_capacity_grown.call(previous_capacity, target)
	return true
