extends SceneTree

## Полный разобранный пример: колония микробов в чашке Петри.
##
##   godot --headless --script res://addons/aegis_ecs/example/colony_example.gd
##
## Клетки блуждают, тратят энергию, расталкиваются, делятся, когда сыты, и
## гибнут, когда голодны. Пример достаточно мал, чтобы прочитать его за один
## присест, и при этом задействует каждую часть библиотеки, которая нужна
## настоящей симуляции:
##
##   * EcsPackedStore          -- данные без шаблонного кода
##   * EcsTagStore             -- признак без данных
##   * UniformSpatialGrid      -- «кто рядом», в плоском 2D-режиме
##   * SimulationClock         -- ускорение, остающееся воспроизводимым
##   * журнал изменений        -- реакция на рождения и смерти
##   * EcsCapacityPolicySystem -- население, способное удвоиться за секунды
##   * EcsReaperSystem         -- единственная точка уничтожения
##   * фазы                    -- суб-шаги симуляции против работы раз в кадр
##
## Пошаговый разбор — в docs/uk/11-povnyi-pryklad.md.
##
## Внутренние классы примера имеют префикс Colony (ColonyMovementSystem и т.п.):
## инструментов из этого файла не видно снаружи, но Godot запрещает внутреннему
## классу иметь то же имя, что и глобальный `class_name` в проекте, — а имена
## `Context`, `MovementSystem`, `SpatialIndexSystem` в реальной игре обычно
## заняты.

const DISH_RADIUS: float = 60.0
const START_POPULATION: int = 200
const INITIAL_CAPACITY: int = 512
const CROWD_RADIUS: float = 3.0
const MAX_NEIGHBOURS: int = 16
const FOOD_PER_SECOND: float = 1.4
const CROWD_PENALTY: float = 0.55
const DIVIDE_ENERGY: float = 8.0
const DIVIDE_AGE: float = 1.0

const TYPE_CELL: int = 0
const TYPE_DIVIDING: int = 1

const PHASE_SIMULATION: int = 100
const PHASE_STATISTICS: int = 200


# --- Компоненты ---------------------------------------------------------------

## Одно хранилище держит всё, что читается вместе на каждом шаге. Разнести
## позицию и энергию значило бы добавить поиск через sparse в самый горячий цикл.
class ColonyCellStore extends EcsPackedStore:
	var position: PackedVector3Array = PackedVector3Array()
	var heading: PackedFloat32Array = PackedFloat32Array()
	var energy: PackedFloat32Array = PackedFloat32Array()
	var age: PackedFloat32Array = PackedFloat32Array()
	## Сколько соседей замечено в радиусе CROWD_RADIUS на прошлом шаге. Пишет
	## ColonyMovementSystem (которая и так спрашивает сетку), читает ColonyMetabolismSystem —
	## поэтому дорогой пространственный запрос оплачивается ровно один раз.
	var crowding: PackedFloat32Array = PackedFloat32Array()

	func _init() -> void:
		track(&"position", &"heading", &"energy", &"age", &"crowding")


# --- Контекст -----------------------------------------------------------------

class ColonyContext:
	var world: EcsWorld
	var cells: ColonyCellStore
	## Тег, а не поле bool: он даёт системе деления плотный список ровно тех клеток,
	## что готовы, вместо просмотра всех подряд.
	var dividing: EcsTagStore
	var grid: UniformSpatialGrid
	var rng: RandomNumberGenerator

	# Переиспользуемые буферы. Выделены один раз, поэтому ни один кадр не аллоцирует.
	var index_ids: PackedInt32Array = PackedInt32Array()
	var index_points: PackedVector3Array = PackedVector3Array()
	var spawn_buffer: PackedInt32Array = PackedInt32Array()

	var births: int = 0
	var deaths: int = 0
	var peak_population: int = 0

	func resize_scratch(capacity: int) -> void:
		index_ids.resize(capacity)
		index_points.resize(capacity)
		spawn_buffer.resize(capacity)


# --- Системы ------------------------------------------------------------------

## Перестраивает индекс соседей. Обязана выполняться ПОСЛЕ движения и ДО всего,
## что спрашивает «кто рядом» — этот порядок и есть единственная причина, по
## которой система вынесена в отдельный шаг.
class ColonySpatialIndexSystem extends EcsSystem:
	var _context: ColonyContext

	func _init() -> void:
		system_name = "SpatialIndex"
		declare_read(TYPE_CELL).complete_access_metadata()

	func setup(_world: EcsWorld, context) -> void:
		_context = context

	func execute(_delta: float) -> void:
		var cells: ColonyCellStore = _context.cells
		var ids: PackedInt32Array = _context.index_ids
		var points: PackedVector3Array = _context.index_points
		var owners: PackedInt32Array = cells.dense_entities
		var position: PackedVector3Array = cells.position

		var count: int = mini(cells.count, ids.size())
		for slot in count:
			ids[slot] = owners[slot]
			points[slot] = position[slot]
		_context.grid.rebuild(ids, points, count)


## Случайное блуждание плюс расталкивание с близкими соседями.
class ColonyMovementSystem extends EcsSystem:
	var _context: ColonyContext

	func _init() -> void:
		system_name = "Movement"
		requires_time = true
		declare_write(TYPE_CELL).complete_access_metadata()

	func setup(_world: EcsWorld, context) -> void:
		_context = context

	func execute(delta: float) -> void:
		var cells: ColonyCellStore = _context.cells
		var grid: UniformSpatialGrid = _context.grid
		var rng: RandomNumberGenerator = _context.rng
		# Локальные псевдонимы: чтение поля на каждой итерации стоило бы в разы дороже.
		var position: PackedVector3Array = cells.position
		var heading: PackedFloat32Array = cells.heading
		var crowding: PackedFloat32Array = cells.crowding
		var owners: PackedInt32Array = cells.dense_entities

		for slot in cells.count:
			var point: Vector3 = position[slot]
			var angle: float = heading[slot] + rng.randf_range(-1.5, 1.5) * delta

			# Уходим от ближайшего соседа, чтобы колония расползалась, а не схлопывалась
			# в одну точку.
			var neighbours: int = grid.query_sphere(point, CROWD_RADIUS, MAX_NEIGHBOURS)
			crowding[slot] = float(maxi(neighbours - 1, 0))
			if neighbours > 1:
				var away := Vector3.ZERO
				for i in neighbours:
					if grid.query_buffer[i] == owners[slot]:
						continue
					away += point - grid.query_point_buffer[i]
				if away.length_squared() > 0.0001:
					angle = AngleMath.approach(angle, atan2(away.x, away.z), 4.0 * delta)

			var speed: float = 6.0
			point.x += sin(angle) * speed * delta
			point.z += cos(angle) * speed * delta

			# Чашка круглая: отражаемся от стенки, доворачивая внутрь.
			var from_centre: float = sqrt(point.x * point.x + point.z * point.z)
			if from_centre > DISH_RADIUS:
				var inward: float = atan2(-point.x, -point.z)
				angle = inward
				point.x *= DISH_RADIUS / from_centre
				point.z *= DISH_RADIUS / from_centre

			position[slot] = point
			heading[slot] = angle


## Старит каждую клетку, тратит энергию и решает, кто готов делиться, а кто
## оголодал. Оба исхода здесь только ПОМЕЧАЮТСЯ.
class ColonyMetabolismSystem extends EcsSystem:
	var _context: ColonyContext

	func _init() -> void:
		system_name = "Metabolism"
		requires_time = true
		declare_write(TYPE_CELL)
		declare_structural_write(TYPE_DIVIDING)
		writes_world_structure = true
		complete_access_metadata()

	func setup(_world: EcsWorld, context) -> void:
		_context = context

	func execute(delta: float) -> void:
		var cells: ColonyCellStore = _context.cells
		var world: EcsWorld = _context.world
		var dividing: EcsTagStore = _context.dividing
		var energy: PackedFloat32Array = cells.energy
		var age: PackedFloat32Array = cells.age
		var crowding: PackedFloat32Array = cells.crowding
		var owners: PackedInt32Array = cells.dense_entities

		for slot in cells.count:
			age[slot] += delta
			# Еда делится локально: одинокая клетка набирает, клетка в тесноте голодает.
			# Эта единственная строка и заставляет колонию расползаться, а затем
			# устанавливаться, вместо того чтобы расти без предела.
			energy[slot] += (FOOD_PER_SECOND - crowding[slot] * CROWD_PENALTY) * delta

			var entity: int = owners[slot]
			if energy[slot] <= 0.0:
				# Только помечает. Клетка живёт до работы жнеца, поэтому этот обход не
				# рассыпается у нас под ногами.
				world.queue_destroy(entity)
			elif energy[slot] >= DIVIDE_ENERGY and age[slot] >= DIVIDE_AGE:
				dividing.attach(entity)


## Делит надвое каждую готовую клетку. Создавать сущности посреди кадра
## безопасно: attach только ДОПИСЫВАЕТ в конец плотного массива и никогда ничего
## не переносит, поэтому цикл ниже не может быть нарушен теми клетками, которые
## он же и создаёт.
class ColonyDivisionSystem extends EcsSystem:
	var _context: ColonyContext

	func _init() -> void:
		system_name = "Division"
		requires_time = true
		declare_write(TYPE_CELL)
		declare_structural_write(TYPE_DIVIDING)
		writes_world_structure = true
		complete_access_metadata()

	func setup(_world: EcsWorld, context) -> void:
		_context = context

	func execute(_delta: float) -> void:
		var dividing: EcsTagStore = _context.dividing
		if dividing.count == 0:
			return

		var world: EcsWorld = _context.world
		var cells: ColonyCellStore = _context.cells
		var rng: RandomNumberGenerator = _context.rng
		var parents: int = mini(dividing.count, _context.spawn_buffer.size())

		# Один пакетный вызов вместо вызова на каждую дочернюю клетку.
		var born: int = world.create_entities(parents, _context.spawn_buffer)
		if born <= 0:
			return
		var first_slot: int = cells.count
		cells.attach_many(_context.spawn_buffer, born)

		var ready: PackedInt32Array = dividing.dense_entities
		for i in born:
			var parent: int = ready[i]
			var parent_slot: int = cells.index_of(parent)
			if parent_slot == -1:
				continue
			var child_slot: int = first_slot + i

			# Родитель платит за деление; обе половины начинают заново.
			cells.energy[parent_slot] *= 0.5
			cells.age[parent_slot] = 0.0

			cells.position[child_slot] = cells.position[parent_slot] \
				+ Vector3(rng.randf_range(-0.4, 0.4), 0.0, rng.randf_range(-0.4, 0.4))
			cells.heading[child_slot] = rng.randf_range(-PI, PI)
			cells.energy[child_slot] = cells.energy[parent_slot]
			cells.age[child_slot] = 0.0
			cells.crowding[child_slot] = cells.crowding[parent_slot]

		# Тег отработал своё на этом шаге. clear() почти O(1) и не аллоцирует, в
		# отличие от поочерёдного отсоединения каждой сущности.
		dividing.clear()


## Читает журнал изменений, который хранилища вели за нас, и очищает его.
## Зарегистрирована ПОСЛЕ жнеца, поэтому к этому моменту `added` содержит
## рождения этого кадра, а `removed` — его смерти.
class ColonyStatisticsSystem extends EcsSystem:
	var _context: ColonyContext

	func _init() -> void:
		system_name = "Statistics"
		complete_access_metadata()

	func setup(_world: EcsWorld, context) -> void:
		_context = context

	func execute(_delta: float) -> void:
		var cells: ColonyCellStore = _context.cells
		_context.births += cells.added_count
		_context.deaths += cells.removed_count
		_context.peak_population = maxi(_context.peak_population, _context.world.get_live_count())
		_context.world.clear_change_logs()


# --- Сборка -------------------------------------------------------------------

func _init() -> void:
	print("=== Aegis ECS: colony example ===")

	var context := ColonyContext.new()
	context.world = EcsWorld.new(INITIAL_CAPACITY)
	context.rng = RandomNumberGenerator.new()
	context.rng.seed = 20260902
	context.resize_scratch(INITIAL_CAPACITY)

	context.cells = ColonyCellStore.new()
	context.dividing = EcsTagStore.new()
	context.world.register_store(context.cells, TYPE_CELL)
	context.world.register_store(context.dividing, TYPE_DIVIDING)

	# Рождения и смерти нужны как события, поэтому включаем журнал у этого хранилища.
	context.cells.track_changes = true

	# Чашка — это плоскость, поэтому сетка получает один слой по Y: меньше ячеек
	# обходить на каждой перестройке, и совершенно бесплатно.
	context.grid = UniformSpatialGrid.new()
	var cell_size: float = UniformSpatialGrid.suggest_cell_size(
		DISH_RADIUS, 0.0, START_POPULATION * 4, CROWD_RADIUS)
	context.grid.configure(DISH_RADIUS, 0.0, cell_size, INITIAL_CAPACITY)
	context.grid.store_query_points = true
	print("grid: cell_size=%.2f, cells=%d, flat=%s"
		% [cell_size, context.grid.get_cell_count(), context.grid.is_flat()])

	var policy := EcsCapacityPolicySystem.new(context.world)
	policy.grow_threshold = 0.75
	policy.growth_factor = 2.0
	policy.maximum_capacity = 20000
	policy.check_interval_frames = 10
	policy.on_capacity_grown = func(_previous: int, next: int) -> void:
		# Библиотека увеличивает свои буферы; всё, что игра выделила рядом с ними —
		# ответственность самой игры.
		context.resize_scratch(next)
		context.grid.configure(DISH_RADIUS, 0.0, cell_size, next)

	# Порядок регистрации ЕСТЬ поведение. Читайте его сверху вниз как алгоритм.
	var scheduler := EcsScheduler.new()
	scheduler.add_system(ColonyMovementSystem.new(), PHASE_SIMULATION)
	scheduler.add_system(ColonySpatialIndexSystem.new(), PHASE_SIMULATION)
	scheduler.add_system(ColonyMetabolismSystem.new(), PHASE_SIMULATION)
	scheduler.add_system(ColonyDivisionSystem.new(), PHASE_SIMULATION)
	scheduler.add_system(EcsReaperSystem.new(context.world), PHASE_SIMULATION)
	scheduler.add_system(policy, PHASE_SIMULATION)
	scheduler.add_system(ColonyStatisticsSystem.new(), PHASE_STATISTICS)
	scheduler.setup_all(context.world, context)

	if not scheduler.validate_pipeline(context.world):
		push_error("pipeline did not validate")

	_seed_colony(context)

	# Фиксированный шаг делает результат воспроизводимым при любой частоте кадров и
	# любом запрошенном ускорении.
	var clock := SimulationClock.new()
	clock.fixed_step = 1.0 / 30.0
	clock.time_scale = 8.0
	clock.max_substeps = 12

	print("\nframe  population  births  deaths  capacity")
	for frame in 360:
		var frame_delta: float = 1.0 / 60.0
		var substeps: int = clock.advance(frame_delta)

		scheduler.begin_frame()
		for step in substeps:
			scheduler.execute_phase(PHASE_SIMULATION, clock.fixed_step)
		# Статистика выполняется раз на отрисованный кадр, а не на каждый суб-шаг.
		scheduler.execute_phase(PHASE_STATISTICS, frame_delta)

		if frame % 60 == 0:
			print("%5d  %10d  %6d  %6d  %8d" % [frame, context.world.get_live_count(),
				context.births, context.deaths, context.world.capacity])

	print("\n--- result ---")
	print("simulated %.1f s of colony time in 360 rendered frames (time_scale %.0f)"
		% [clock.elapsed_simulated, clock.time_scale])
	print("population %d, peak %d, births %d, deaths %d"
		% [context.world.get_live_count(), context.peak_population,
		   context.births, context.deaths])
	print("capacity grew %d times, now %d" % [policy.growth_count, context.world.capacity])
	print("dropped substeps: %d" % clock.dropped_substeps)

	print("\n--- profile (usec per frame, smoothed) ---")
	for i in scheduler.get_system_count():
		print("  %-16s %6d" % [scheduler.get_system_name(i),
			int(scheduler.get_average_timing_usec(i))])

	var healthy: bool = context.world.validate_integrity()
	print("\nworld integrity: %s" % ("OK" if healthy else "BROKEN"))
	print("RESULT: %s" % ("OK" if healthy and context.births > 0 else "FAILED"))
	quit(0 if healthy and context.births > 0 else 1)


func _seed_colony(context: ColonyContext) -> void:
	var spawned: int = context.world.create_entities(START_POPULATION, context.spawn_buffer)
	var first_slot: int = context.cells.count
	context.cells.attach_many(context.spawn_buffer, spawned)
	for i in spawned:
		var slot: int = first_slot + i
		var angle: float = context.rng.randf_range(-PI, PI)
		var distance: float = sqrt(context.rng.randf()) * DISH_RADIUS * 0.4
		context.cells.position[slot] = Vector3(sin(angle) * distance, 0.0, cos(angle) * distance)
		context.cells.heading[slot] = context.rng.randf_range(-PI, PI)
		context.cells.energy[slot] = context.rng.randf_range(4.0, 7.0)
		context.cells.age[slot] = 0.0
		context.cells.crowding[slot] = 0.0
	print("seeded %d cells" % spawned)
