class_name EcsReaperSystem
extends EcsSystem

## Единственная система, которая на самом деле уничтожает сущности.
##
## Все остальные системы только зовут [method EcsWorld.queue_destroy]; реальное
## удаление происходит здесь, в [method EcsWorld.flush_destroy_queue]. Этот
## класс существует ради того, чтобы самое важное правило библиотеки было тем,
## что РЕГИСТРИРУЮТ, а не тем, что нужно не забыть написать:
##
## [codeblock]
## scheduler.add_system(SpawnSystem.new())
## scheduler.add_system(MovementSystem.new())
## scheduler.add_system(DamageSystem.new())
## scheduler.add_system(EcsReaperSystem.new(world))   # всегда последней
## [/codeblock]
##
## [b]Ставьте её последней, и ровно одну на конвейер.[/b] Flush посреди кадра
## позволил бы плотному слоту, закешированному более ранней системой, указывать
## уже на другую сущность к моменту, когда его прочитает более поздняя — это
## use-after-free, который не падает, а тихо выдаёт неверные данные. Второй
## жнец где-то ещё в списке ломает ту же гарантию.
##
## Он намеренно НЕ объявляет [member EcsSystem.requires_time]: сущности,
## помеченные на уничтожение перед паузой, всё равно должны быть прибраны —
## иначе они висят в очереди и во всех хранилищах всё время, пока игра на паузе.
##
## [b]Как реагировать на смерти[/b]: включите
## [member EcsComponentStore.track_changes] у нужных хранилищ и зарегистрируйте
## своего читателя СРАЗУ ПОСЛЕ этой системы. К этому моменту `added_entities`
## содержит всё, что появилось за кадр, а `removed_entities` — всё, что за кадр
## погибло; закончив, вызовите [method EcsWorld.clear_change_logs].

## Сколько сущностей уничтожено за последний [method execute]. Удобно для
## телеметрии и для запуска эффектов или звуков смерти.
var last_reaped: int = 0

## Сколько сущностей уничтожено всего с момента создания системы.
var total_reaped: int = 0

var _world: EcsWorld


func _init(world: EcsWorld = null, system_display_name: String = "Reaper") -> void:
	system_name = system_display_name
	writes_world_structure = true
	complete_access_metadata()
	_world = world


## Обычно мир передают в [method _init]. Это переопределение дополнительно
## принимает его из объекта-контекста, у которого есть свойство `world`, — так
## работают оба стиля сборки.
func setup(world: EcsWorld, context) -> void:
	if _world == null:
		_world = world
	if _world == null and context != null and context.get(&"world") != null:
		_world = context.get(&"world")
	if _world == null:
		push_error("EcsReaperSystem: нет мира — передайте его в _init() или в setup()")


func execute(_delta: float) -> void:
	if _world == null:
		return
	last_reaped = _world.flush_destroy_queue()
	total_reaped += last_reaped
