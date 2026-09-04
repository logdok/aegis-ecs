extends SceneTree

## Минимальный, но ПОЛНЫЙ пример Aegis ECS — и одновременно самопроверка аддона.
##
## Запуск из корня проекта, содержащего аддон:
##   godot --headless --script res://addons/aegis_ecs/example/minimal_example.gd
##
## Показывает всё, что нужно для старта:
##   1. объявление хранилища компонентов без шаблонного кода (EcsPackedStore);
##   2. объявление системы и доступ к данным через собственный контекст;
##   3. сборку мира и порядок, в котором всё регистрируется;
##   4. правило «уничтожение происходит ровно в одной точке» (EcsReaperSystem);
##   5. пакетный спавн;
##   6. чтение встроенного профайлера.
##
## Классы здесь объявлены ВНУТРЕННИМИ (`class ... extends ...`), а не через
## `class_name`, чтобы пример ничего не добавлял в глобальное пространство имён
## вашего проекта.


# --- 1. Хранилища компонентов -------------------------------------------------

## Данные компонента живут в параллельных Packed-массивах, адресуемых плотным
## слотом. Наследование от EcsPackedStore означает объявить поля и один раз их
## назвать: выделение памяти, рост и перенос при swap-remove сделаны за вас.
##
## (Более низкоуровневый EcsComponentStore никуда не делся — если хранилищу
## нужен полный ручной контроль; тогда оно обязано само реализовать
## _reserve_dense и _relocate_dense, и забытый второй тихо портит данные при
## удалении.)
class PositionStore extends EcsPackedStore:
	var x: PackedFloat32Array = PackedFloat32Array()
	var y: PackedFloat32Array = PackedFloat32Array()

	func _init() -> void:
		track(&"x", &"y")

	## Удобная обёртка: присоединить компонент и заполнить его одним вызовом.
	func assign(entity: int, start_x: float, start_y: float) -> int:
		var slot: int = attach(entity)
		if slot < 0:
			return slot
		x[slot] = start_x
		y[slot] = start_y
		return slot


class VelocityStore extends EcsPackedStore:
	var dx: PackedFloat32Array = PackedFloat32Array()
	var dy: PackedFloat32Array = PackedFloat32Array()

	func _init() -> void:
		track(&"dx", &"dy")

	func assign(entity: int, vx: float, vy: float) -> int:
		var slot: int = attach(entity)
		if slot < 0:
			return slot
		dx[slot] = vx
		dy[slot] = vy
		return slot


# --- 2. Ваш контекст ----------------------------------------------------------

## Библиотека ничего не знает о вашей игре: она просто отдаёт этот объект каждой
## системе в setup(). Держите здесь ссылки на хранилища и общее состояние, чтобы
## системам никогда не приходилось знать друг о друге напрямую.
class Context:
	var world: EcsWorld
	var positions: PositionStore
	var velocities: VelocityStore
	var alive_tag: EcsTagStore
	var escaped_count: int = 0


# --- 3. Системы ---------------------------------------------------------------

## Интегрирует скорость в позицию. Обратите внимание на обход: идём по ПЛОТНОМУ
## массиву меньшего хранилища, а второй компонент добираем через sparse-индекс.
## Это самый быстрый уровень API; EcsView и EcsQuery закрывают случаи, когда
## состав компонентов меняется.
class MovementSystem extends EcsSystem:
	var _context: Context

	func _init() -> void:
		system_name = "Movement"
		# Пока время стоит, делать нечего, поэтому пусть планировщик пропустит вызов
		# целиком, вместо того чтобы открывать execute() ранним возвратом.
		requires_time = true
		declare_read(TYPE_VELOCITY).declare_write(TYPE_POSITION).complete_access_metadata()

	func setup(_world: EcsWorld, context) -> void:
		_context = context

	func execute(delta: float) -> void:
		var positions: PositionStore = _context.positions
		var velocities: VelocityStore = _context.velocities

		# Локальные псевдонимы Packed-массивов: читать локальную переменную в цикле
		# заметно дешевле, чем поле объекта на каждой итерации.
		var pos_slots: PackedInt32Array = positions.sparse_index
		var px: PackedFloat32Array = positions.x
		var py: PackedFloat32Array = positions.y
		var dx: PackedFloat32Array = velocities.dx
		var dy: PackedFloat32Array = velocities.dy
		var owners: PackedInt32Array = velocities.dense_entities

		for dense in velocities.count:
			var slot: int = pos_slots[owners[dense]]
			if slot < 0:
				continue
			px[slot] += dx[dense] * delta
			py[slot] += dy[dense] * delta

		# В Godot 4 Packed-массивы передаются по ссылке: локальные псевдонимы уже
		# записали в хранилище. Обратное присваивание не требуется.


## Ставит в очередь на уничтожение всех, кто покинул арену.
class BoundsSystem extends EcsSystem:
	var _context: Context
	var _limit: float

	func _init(limit: float) -> void:
		system_name = "Bounds"
		requires_time = true
		_limit = limit
		declare_read(TYPE_POSITION)
		writes_world_structure = true
		complete_access_metadata()

	func setup(_world: EcsWorld, context) -> void:
		_context = context

	func execute(_delta: float) -> void:
		var positions: PositionStore = _context.positions
		var world: EcsWorld = _context.world
		var px: PackedFloat32Array = positions.x
		var owners: PackedInt32Array = positions.dense_entities

		for dense in positions.count:
			if absf(px[dense]) > _limit:
				# Только ПОМЕЧАЕТ. Сущность живёт до конца кадра, поэтому этот плотный обход
				# не рассыпается у нас под ногами.
				world.queue_destroy(owners[dense])
				_context.escaped_count += 1


# --- 4. Сборка и запуск -------------------------------------------------------

const TYPE_POSITION: int = 0
const TYPE_VELOCITY: int = 1
const TYPE_ALIVE: int = 2

const POPULATION: int = 500

var _failures: int = 0


func _init() -> void:
	print("=== Aegis ECS: minimal example ===")

	var context := Context.new()
	context.world = EcsWorld.new(1000)

	# Хранилища: создать, затем зарегистрировать. Регистрация выделяет их
	# внутренние массивы под ёмкость мира и обязана произойти до первой сущности.
	context.positions = PositionStore.new()
	context.velocities = VelocityStore.new()
	context.alive_tag = EcsTagStore.new()
	context.world.register_store(context.positions, TYPE_POSITION)
	context.world.register_store(context.velocities, TYPE_VELOCITY)
	context.world.register_store(context.alive_tag, TYPE_ALIVE)

	# Порядок регистрации = порядок исполнения = поведение. Движение должно
	# отработать до проверки границ, а уничтожение — последним.
	var scheduler := EcsScheduler.new()
	scheduler.add_system(MovementSystem.new())
	scheduler.add_system(BoundsSystem.new(100.0))
	scheduler.add_system(EcsReaperSystem.new(context.world))
	scheduler.setup_all(context.world, context)
	_expect(scheduler.validate_pipeline(context.world), "the pipeline validates")

	# Пакетный спавн: один вызов вместо POPULATION вызовов. Идентификаторы падают
	# в переиспользуемый буфер, а attach_many() даёт компонентам подряд идущие слоты.
	var spawn_buffer := PackedInt32Array()
	spawn_buffer.resize(POPULATION)
	var spawned: int = context.world.create_entities(POPULATION, spawn_buffer)
	_expect(spawned == POPULATION, "created %d entities in one batch" % POPULATION)

	var rng := RandomNumberGenerator.new()
	rng.seed = 20260822
	for i in spawned:
		var entity: int = spawn_buffer[i]
		context.positions.assign(entity, 0.0, 0.0)
		context.velocities.assign(entity, rng.randf_range(-40.0, 40.0), 0.0)
	context.alive_tag.attach_many(spawn_buffer, spawned)

	_expect(context.world.get_live_count() == POPULATION, "the world holds %d entities" % POPULATION)
	_expect(context.positions.count == POPULATION, "%d position components" % POPULATION)
	_expect(context.alive_tag.count == POPULATION, "attach_many() tagged the whole batch")

	# Кадры: за 10 секунд модельного времени все успевают уйти за границу.
	for frame in 600:
		scheduler.execute_all(1.0 / 60.0)

	print("still alive: %d, escaped: %d" % [context.world.get_live_count(), context.escaped_count])
	_expect(context.escaped_count > 0, "some entities left the arena")
	_expect(context.world.get_live_count() + context.escaped_count == POPULATION,
		"the entity balance adds up")
	_expect(context.positions.count == context.world.get_live_count(),
		"the store agrees with the world after destruction")

	# Пауза: шаг нулевой длины не должен менять ничего.
	var before: int = context.world.get_live_count()
	scheduler.execute_all(0.0)
	_expect(context.world.get_live_count() == before, "a zero-length step changed nothing")

	# Сброс мира переиспользует каждый уже выделенный байт.
	context.world.reset()
	_expect(context.world.get_live_count() == 0, "reset() emptied the world")
	_expect(context.positions.count == 0, "reset() emptied the stores")

	# Поиск хранилища по типу — для сборки и отладки, не для горячих циклов.
	_expect(context.world.get_store(TYPE_POSITION) == context.positions,
		"get_store() finds a store by type")

	print("--- profiling (usec, last frame) ---")
	for i in scheduler.get_system_count():
		print("  %-10s %6d" % [scheduler.get_system_name(i), int(scheduler.get_timing_usec(i))])

	print("RESULT: %s" % ("OK" if _failures == 0 else "FAILED (%d)" % _failures))
	quit(1 if _failures > 0 else 0)


func _expect(condition: bool, label: String) -> void:
	if condition:
		print("  ok   %s" % label)
	else:
		_failures += 1
		print("  FAIL %s" % label)
