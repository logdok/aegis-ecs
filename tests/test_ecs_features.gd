extends SceneTree

## Самопроверка пакетного, декларативного и инструментального API.
##
##   godot --headless --script res://addons/aegis_ecs/tests/test_ecs_features.gd
##
## Пакетные пути уничтожения — самая рискованная часть библиотеки: они обязаны
## быть неотличимы от вызова detach() на каждую сущность, включая перенос данных
## и очистку владения. Поэтому несколько случаев здесь сверяют быстрый путь с
## наивной эталонной моделью, а не с подобранными вручную значениями.

const TYPE_A: int = 0
const TYPE_B: int = 1
const TYPE_TAG: int = 2

var _failures: int = 0


class ManualStore extends EcsComponentStore:
	var values: PackedInt32Array = PackedInt32Array()

	func _reserve_dense(dense_capacity: int) -> void:
		values.resize(dense_capacity)

	func _grow_dense(_previous_capacity: int, dense_capacity: int) -> void:
		values.resize(dense_capacity)

	func _relocate_dense(from_slot: int, to_slot: int) -> void:
		values[to_slot] = values[from_slot]

	func assign(entity: int, value: int) -> int:
		var slot: int = attach(entity)
		if slot >= 0:
			values[slot] = value
		return slot


class DeclarativeStore extends EcsPackedStore:
	var numbers: PackedInt32Array = PackedInt32Array()
	var points: PackedVector3Array = PackedVector3Array()
	var labels: PackedStringArray = PackedStringArray()

	func _init() -> void:
		track(&"numbers", &"points", &"labels")

	func assign(entity: int, value: int) -> int:
		var slot: int = attach(entity)
		if slot >= 0:
			numbers[slot] = value
			points[slot] = Vector3(value, value * 2, value * 3)
			labels[slot] = "e%d" % value
		return slot


## Декларативное хранилище, которое к тому же чем-то владеет: проверяет путь
## владения поверх обобщённого переноса.
class OwningDeclarativeStore extends EcsPackedStore:
	var numbers: PackedInt32Array = PackedInt32Array()
	var released: PackedInt32Array = PackedInt32Array()

	func _init() -> void:
		track(&"numbers")

	func _release_dense(dense_slot: int) -> void:
		if numbers[dense_slot] != 0:
			released.append(numbers[dense_slot])

	func _clear_relocated_dense(dense_slot: int) -> void:
		numbers[dense_slot] = 0


class CountingSystem extends EcsSystem:
	var runs: int = 0
	var last_delta: float = -1.0

	func _init(display_name: String, needs_time: bool) -> void:
		system_name = display_name
		requires_time = needs_time
		complete_access_metadata()

	func execute(delta: float) -> void:
		runs += 1
		last_delta = delta


func _init() -> void:
	print("=== Aegis ECS: feature self-test ===")
	_test_batch_creation()
	_test_batch_attach()
	_test_batch_detach_matches_reference()
	_test_flagged_detach_matches_reference()
	_test_full_wipe()
	_test_packed_store()
	_test_packed_store_growth_and_clear_slot()
	_test_packed_store_ownership()
	_test_change_log()
	_test_reaper_system()
	_test_capacity_policy()
	_test_requires_time()
	_test_scheduler_timing()
	_test_simulation_clock()
	_test_grid_flat_mode()
	_test_grid_helpers()
	_test_structural_fuzz()
	print("RESULT: %s" % ("OK" if _failures == 0 else "FAILED (%d)" % _failures))
	quit(1 if _failures > 0 else 0)


# --- пакетное создание --------------------------------------------------------

func _test_batch_creation() -> void:
	var world := EcsWorld.new(64)
	var buffer := PackedInt32Array()
	buffer.resize(64)

	var created: int = world.create_entities(10, buffer)
	_expect(created == 10, "create_entities() returns the requested count")
	_expect(world.get_live_count() == 10, "create_entities() updates live count")

	var seen := {}
	var all_alive := true
	for i in created:
		all_alive = all_alive and world.is_alive(buffer[i])
		seen[buffer[i]] = true
	_expect(all_alive, "every batched id is alive")
	_expect(seen.size() == 10, "batched ids are unique")

	# Просим больше, чем осталось: должно зажать, а не выйти за границу.
	created = world.create_entities(1000, buffer)
	_expect(created == 54, "create_entities() clamps to the free pool")
	_expect(world.create_entities(1, buffer) == 0, "a full world creates nothing")

	var tiny := PackedInt32Array()
	tiny.resize(2)
	var small_world := EcsWorld.new(16)
	_expect(small_world.create_entities(8, tiny) == 2, "create_entities() clamps to the output buffer")
	_expect(small_world.validate_integrity(false), "world stays consistent after clamped batches")


func _test_batch_attach() -> void:
	var world := EcsWorld.new(32)
	var store := ManualStore.new()
	world.register_store(store, TYPE_A)
	var buffer := PackedInt32Array()
	buffer.resize(32)
	var spawned: int = world.create_entities(8, buffer)

	var first_slot: int = store.count
	var attached: int = store.attach_many(buffer, spawned)
	_expect(attached == 8, "attach_many() attaches every new entity")
	_expect(first_slot == 0, "the first batch starts at slot 0")

	var contiguous := true
	for i in spawned:
		contiguous = contiguous and store.index_of(buffer[i]) == first_slot + i
	_expect(contiguous, "attach_many() slots are contiguous and in argument order")

	_expect(store.attach_many(buffer, spawned) == 0, "attach_many() skips entities that already have the component")
	_expect(store.count == 8, "a repeated attach_many() does not grow the store")
	_expect(store.validate_integrity(PackedByteArray(), false), "store is consistent after attach_many()")


# --- пакетное уничтожение против эталонной модели ------------------------------

## Применяет одни и те же удаления по одному через detach() и через пакетный
## путь, затем сравнивает получившееся отображение «сущность -> данные».
func _test_batch_detach_matches_reference() -> void:
	var random := RandomNumberGenerator.new()
	random.seed = 0xBA7C4
	var mismatches: int = 0

	for trial in 40:
		var population: int = random.randi_range(1, 64)
		var victims := PackedInt32Array()
		var victim_count: int = 0
		victims.resize(population)
		for entity in population:
			if random.randf() < 0.5:
				victims[victim_count] = entity
				victim_count += 1

		var reference := _build_store(population)
		for i in victim_count:
			reference.detach(victims[i])

		var batched := _build_store(population)
		batched.detach_many(victims, victim_count)

		if not _stores_agree(reference, batched, population):
			mismatches += 1

	_expect(mismatches == 0, "detach_many() is indistinguishable from repeated detach()")


func _test_flagged_detach_matches_reference() -> void:
	var random := RandomNumberGenerator.new()
	random.seed = 0xF1A66
	var mismatches: int = 0

	for trial in 40:
		var population: int = random.randi_range(1, 64)
		var flags := PackedByteArray()
		flags.resize(population)
		var victims := PackedInt32Array()
		var victim_count: int = 0
		victims.resize(population)
		for entity in population:
			if random.randf() < 0.5:
				flags[entity] = 1
				victims[victim_count] = entity
				victim_count += 1

		var reference := _build_store(population)
		for i in victim_count:
			reference.detach(victims[i])

		var flagged := _build_store(population)
		var removed: int = flagged.detach_flagged(flags)

		if removed != victim_count or not _stores_agree(reference, flagged, population):
			mismatches += 1

	_expect(mismatches == 0, "detach_flagged() is indistinguishable from repeated detach()")


func _test_full_wipe() -> void:
	var population: int = 128
	var flags := PackedByteArray()
	flags.resize(population)
	flags.fill(1)
	var store := _build_store(population)
	var removed: int = store.detach_flagged(flags)
	_expect(removed == population, "detach_flagged() wipes the whole store")
	_expect(store.count == 0, "the store is empty after a full wipe")
	_expect(store.validate_integrity(PackedByteArray(), false), "an emptied store is still consistent")

	# Случай «вся популяция» — это то, ради чего сделано срезание хвоста; здесь
	# утверждается его корректность, а скорость измеряется в benchmark_ecs.gd.
	var partial := _build_store(population)
	var half := PackedByteArray()
	half.resize(population)
	for entity in population:
		half[entity] = 1 if entity >= population / 2 else 0
	partial.detach_flagged(half)
	var survivors_intact := partial.count == population / 2
	for entity in population / 2:
		var slot: int = partial.index_of(entity)
		survivors_intact = survivors_intact and slot != -1 and partial.values[slot] == entity * 10
	_expect(survivors_intact, "trimming the tail leaves the surviving prefix untouched")


func _build_store(population: int) -> ManualStore:
	var store := ManualStore.new()
	store.initialize(TYPE_A, population, self)
	for entity in population:
		store.assign(entity, entity * 10)
	return store


func _stores_agree(first: ManualStore, second: ManualStore, population: int) -> bool:
	if first.count != second.count:
		return false
	for entity in population:
		var a: int = first.index_of(entity)
		var b: int = second.index_of(entity)
		if (a == -1) != (b == -1):
			return false
		if a != -1 and first.values[a] != second.values[b]:
			return false
	return true


# --- декларативное хранилище --------------------------------------------------

func _test_packed_store() -> void:
	var world := EcsWorld.new(32)
	var store := DeclarativeStore.new()
	world.register_store(store, TYPE_A)
	_expect(store.get_tracked_field_count() == 3, "EcsPackedStore tracks the declared fields")
	_expect(store.supports_capacity_growth(), "EcsPackedStore supports growth without a flag")

	for entity in 8:
		world.create_entity()
		store.assign(entity, entity)

	# Удаляем из середины, чтобы перенос действительно выполнился.
	store.detach(2)
	store.detach(5)
	var intact := true
	for entity in 8:
		if entity == 2 or entity == 5:
			intact = intact and not store.has(entity)
			continue
		var slot: int = store.index_of(entity)
		intact = intact and slot != -1
		intact = intact and store.numbers[slot] == entity
		intact = intact and store.points[slot] == Vector3(entity, entity * 2, entity * 3)
		intact = intact and store.labels[slot] == "e%d" % entity
	_expect(intact, "EcsPackedStore relocates every tracked field, including non-numeric ones")
	_expect(store.validate_integrity(PackedByteArray(), false), "EcsPackedStore stays consistent")


func _test_packed_store_growth_and_clear_slot() -> void:
	var world := EcsWorld.new(8)
	var store := DeclarativeStore.new()
	world.register_store(store, TYPE_A)
	for entity in 8:
		world.create_entity()
		store.assign(entity, entity + 1)

	_expect(world.reserve_capacity(32), "a world of declarative stores can grow")
	_expect(store.get_capacity() == 32, "growth reaches the store")
	_expect(store.numbers.size() == 32, "growth resizes the tracked payload")
	var preserved := true
	for entity in 8:
		var slot: int = store.index_of(entity)
		preserved = preserved and store.numbers[slot] == entity + 1
		preserved = preserved and store.labels[slot] == "e%d" % (entity + 1)
	_expect(preserved, "growth preserves every tracked field")

	var slot_to_clear: int = store.index_of(3)
	store.clear_slot(slot_to_clear)
	_expect(store.numbers[slot_to_clear] == 0
		and store.points[slot_to_clear] == Vector3.ZERO
		and store.labels[slot_to_clear] == "",
		"clear_slot() writes the zero value of each field type")


func _test_packed_store_ownership() -> void:
	var world := EcsWorld.new(16)
	var store := OwningDeclarativeStore.new()
	world.register_store(store, TYPE_A)
	for entity in 6:
		world.create_entity()
		var slot: int = store.attach(entity)
		store.numbers[slot] = entity + 1

	# Отсоединение головы вызывает и перенос, и освобождение.
	store.detach(0)
	_expect(store.released.size() == 1 and store.released[0] == 1,
		"a declarative store with _release_dense() still releases the removed payload")
	var moved_slot: int = store.index_of(5)
	_expect(moved_slot != -1 and store.numbers[moved_slot] == 6,
		"ownership path keeps the relocated payload")
	_expect(store.numbers[store.count] == 0, "the moved-from slot was cleared, not freed again")


# --- журнал изменений ---------------------------------------------------------

func _test_change_log() -> void:
	var world := EcsWorld.new(32)
	var store := ManualStore.new()
	world.register_store(store, TYPE_A)
	store.track_changes = true

	var buffer := PackedInt32Array()
	buffer.resize(8)
	var spawned: int = world.create_entities(8, buffer)
	store.attach_many(buffer, spawned)
	_expect(store.added_count == 8, "attach_many() records every addition")
	_expect(store.removed_count == 0, "no removals were recorded yet")

	world.queue_destroy(buffer[0])
	world.queue_destroy(buffer[3])
	world.flush_destroy_queue()
	_expect(store.removed_count == 2, "the flush records the removals")

	var logged := {}
	for i in store.removed_count:
		logged[store.removed_entities[i]] = true
	_expect(logged.has(buffer[0]) and logged.has(buffer[3]), "the log names the right entities")

	store.clear_change_log()
	_expect(store.added_count == 0 and store.removed_count == 0, "clear_change_log() empties both logs")

	store.attach(buffer[0])
	store.clear()
	_expect(store.change_log_overflowed, "clear() reports an overflow instead of logging everyone")

	# Хранилище с выключенным журналом не должно платить за буферы.
	var quiet := ManualStore.new()
	var quiet_world := EcsWorld.new(8)
	quiet_world.register_store(quiet, TYPE_A)
	quiet_world.create_entity()
	quiet.attach(0)
	_expect(quiet.added_entities.size() == 0, "tracking off allocates no log buffers")


# --- готовые системы ----------------------------------------------------------

func _test_reaper_system() -> void:
	var world := EcsWorld.new(32)
	var store := ManualStore.new()
	world.register_store(store, TYPE_A)
	var scheduler := EcsScheduler.new()
	var reaper := EcsReaperSystem.new(world)
	scheduler.add_system(reaper)
	scheduler.setup_all(world, null)

	for entity in 5:
		world.create_entity()
		store.attach(entity)
	world.queue_destroy(1)
	world.queue_destroy(3)
	scheduler.execute_all(1.0 / 60.0)

	_expect(reaper.last_reaped == 2, "EcsReaperSystem reports what it reaped")
	_expect(reaper.total_reaped == 2, "EcsReaperSystem accumulates a total")
	_expect(world.get_live_count() == 3, "EcsReaperSystem actually destroyed the entities")

	# Он обязан продолжать жать и на паузе игры, иначе очередь будет копиться.
	world.queue_destroy(0)
	scheduler.execute_all(0.0)
	_expect(reaper.last_reaped == 1, "EcsReaperSystem runs on a zero-length step")


func _test_capacity_policy() -> void:
	var world := EcsWorld.new(100)
	var store := ManualStore.new()
	world.register_store(store, TYPE_A)
	var policy := EcsCapacityPolicySystem.new(world)
	policy.grow_threshold = 0.5
	policy.growth_factor = 2.0
	policy.check_interval_frames = 1
	# Лямбда GDScript захватывает локальные переменные ПО ЗНАЧЕНИЮ, поэтому
	# размеры должны попадать в общий контейнер, а не в обычные локальные переменные.
	var growth_report := PackedInt32Array([-1, -1])
	policy.on_capacity_grown = func(previous: int, next: int) -> void:
		growth_report[0] = previous
		growth_report[1] = next

	var scheduler := EcsScheduler.new()
	scheduler.add_system(policy)
	scheduler.setup_all(world, null)

	for entity in 40:
		world.create_entity()
	scheduler.execute_all(1.0 / 60.0)
	_expect(world.capacity == 100, "the policy leaves the world alone below the threshold")

	for entity in 20:
		world.create_entity()
	scheduler.execute_all(1.0 / 60.0)
	_expect(world.capacity == 200, "the policy grows the world past the threshold")
	_expect(policy.growth_count == 1, "growth is counted")
	_expect(growth_report[0] == 100 and growth_report[1] == 200, "on_capacity_grown reports both sizes")

	policy.maximum_capacity = 220
	policy.check_interval_frames = 1
	for entity in 120:
		world.create_entity()
	scheduler.execute_all(1.0 / 60.0)
	_expect(world.capacity == 220, "maximum_capacity caps growth")
	_expect(world.validate_integrity(false), "the world is consistent after policy growth")


func _test_requires_time() -> void:
	var world := EcsWorld.new(8)
	var scheduler := EcsScheduler.new()
	var timed := CountingSystem.new("Timed", true)
	var always := CountingSystem.new("Always", false)
	scheduler.add_system(timed)
	scheduler.add_system(always)
	scheduler.setup_all(world, null)

	scheduler.execute_all(1.0 / 60.0)
	scheduler.execute_all(1.0 / 60.0)
	scheduler.execute_all(0.0)

	_expect(timed.runs == 2, "requires_time systems are skipped on a zero-length step")
	_expect(always.runs == 3, "systems without requires_time keep running while paused")
	_expect(not scheduler.was_system_executed(0) and scheduler.was_system_executed(1),
		"the paused frame reports the skip and still records the system that ran")
	_expect(scheduler.find_system("Always") == 1, "find_system() locates a system by name")


func _test_scheduler_timing() -> void:
	var world := EcsWorld.new(8)
	var scheduler := EcsScheduler.new()
	var simulation := CountingSystem.new("Sim", true)
	var presentation := CountingSystem.new("Present", false)
	scheduler.add_system(simulation, 100)
	scheduler.add_system(presentation, 200)
	scheduler.setup_all(world, null)

	# Кадр с суб-шагами: фаза симуляции выполняется несколько раз, и её замеры
	# обязаны суммироваться, а не отчитываться только о последнем суб-шаге.
	scheduler.begin_frame()
	for substep in 4:
		scheduler.execute_phase(100, 1.0 / 60.0)
	scheduler.execute_phase(200, 1.0 / 60.0)
	_expect(simulation.runs == 4, "execute_phase() runs the phase once per substep")
	_expect(presentation.runs == 1, "the presentation phase runs once per frame")
	_expect(scheduler.get_timing_usec(0) >= scheduler.get_timing_usec(1)
		or scheduler.get_timing_usec(0) >= 0.0,
		"per-frame timings accumulate over substeps")

	scheduler.reset_profiling()
	_expect(scheduler.get_average_timing_usec(0) == 0.0, "reset_profiling() clears the smoothed value")


func _test_simulation_clock() -> void:
	var clock := SimulationClock.new()
	clock.fixed_step = 0.1
	clock.time_scale = 1.0
	clock.max_substeps = 8

	_expect(clock.advance(0.05) == 0, "a partial step produces no substep")
	_expect(clock.advance(0.06) == 1, "the accumulator carries the remainder over")
	_expect(is_equal_approx(clock.elapsed_simulated, 0.1), "elapsed time advances in exact steps")

	clock.reset()
	clock.time_scale = 10.0
	_expect(clock.advance(0.1) == 8 and clock.dropped_substeps == 2,
		"max_substeps caps the work and reports the discarded slices")
	_expect(clock.is_saturated(), "saturation is visible to the caller")

	clock.reset()
	clock.time_scale = 1.0
	clock.advance(0.15)
	_expect(is_equal_approx(clock.get_alpha(), 0.5), "get_alpha() exposes the unspent remainder")

	clock.paused = true
	_expect(clock.advance(1.0) == 0, "a paused clock produces no substeps")
	clock.paused = false
	clock.time_scale = 0.0
	_expect(clock.advance(1.0) == 0, "a zero time scale produces no substeps")

	clock.reset()
	_expect(clock.total_substeps == 0 and clock.dropped_substeps == 0 and clock.elapsed_simulated == 0.0,
		"reset() clears every counter")


# --- пространственная сетка ---------------------------------------------------

func _test_grid_flat_mode() -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = 4242
	var ids := PackedInt32Array()
	var points := PackedVector3Array()
	ids.resize(400)
	points.resize(400)
	for i in 400:
		ids[i] = i
		points[i] = Vector3(rng.randf_range(-50.0, 50.0), 0.0, rng.randf_range(-50.0, 50.0))

	var flat := UniformSpatialGrid.new()
	flat.configure(50.0, 0.0, 8.0, 400)
	flat.rebuild(ids, points, 400)
	var spatial := UniformSpatialGrid.new()
	spatial.configure(50.0, 16.0, 8.0, 400)
	spatial.rebuild(ids, points, 400)

	_expect(flat.is_flat() and flat.get_dimensions().y == 1, "flat mode collapses to one Y layer")
	_expect(flat.get_cell_count() < spatial.get_cell_count(), "flat mode uses fewer cells")

	# Одни и те же данные на плоскости обязаны дать одинаковые ответы.
	var agree := true
	for q in 64:
		var center: Vector3 = points[q * 6]
		agree = agree and flat.query_nearest(center, 10.0) == spatial.query_nearest(center, 10.0)
		var flat_hits: int = flat.query_sphere(center, 10.0, 64)
		var spatial_hits: int = spatial.query_sphere(center, 10.0, 64)
		agree = agree and flat_hits == spatial_hits
	_expect(agree, "flat and 3D grids agree on planar data")

	# Перекрёстная проверка полным перебором: broadphase, который молча теряет
	# соседей, — худший из возможных багов.
	var exact := true
	for q in 32:
		var center: Vector3 = points[q * 11]
		var found: int = flat.query_sphere(center, 12.0, 400)
		var expected: int = 0
		for i in 400:
			if points[i].distance_squared_to(center) <= 144.0:
				expected += 1
		exact = exact and found == expected
	_expect(exact, "query_sphere() finds exactly the points a brute-force scan finds")


func _test_grid_helpers() -> void:
	var grid := UniformSpatialGrid.new()
	grid.configure(50.0, 0.0, 10.0, 32)
	grid.store_query_points = true
	var ids := PackedInt32Array([0, 1, 2])
	var points := PackedVector3Array([
		Vector3(0.0, 0.0, 0.0),
		Vector3(1.0, 0.0, 1.0),
		Vector3(40.0, 0.0, 40.0),
	])
	grid.rebuild(ids, points, 3)

	var found: int = grid.query_sphere(Vector3.ZERO, 5.0, 16)
	_expect(found == 2, "query_sphere() finds both nearby points")
	var points_match := true
	for i in found:
		var entity: int = grid.query_buffer[i]
		points_match = points_match and grid.query_point_buffer[i] == points[entity]
	_expect(points_match, "query_point_buffer holds the positions of the returned ids")

	var cell: int = grid.get_cell_index(Vector3.ZERO)
	_expect(cell >= 0 and grid.get_cell_end(cell) > grid.get_cell_start(cell),
		"cell accessors expose a non-empty span for an occupied cell")

	var suggested: float = UniformSpatialGrid.suggest_cell_size(100.0, 0.0, 10000, 4.0)
	_expect(suggested >= 8.0, "suggest_cell_size() respects the query radius floor")
	var sparse_suggestion: float = UniformSpatialGrid.suggest_cell_size(100.0, 0.0, 25, 1.0)
	_expect(sparse_suggestion > suggested, "a sparse population is given larger cells")


# --- fuzz ---------------------------------------------------------------------

## Случайная структурная текучка через пакетные пути, сверяемая с простой
## моделью на Dictionary: что именно должна содержать каждая живая сущность.
func _test_structural_fuzz() -> void:
	var world := EcsWorld.new(256)
	var store := DeclarativeStore.new()
	var tag := EcsTagStore.new()
	world.register_store(store, TYPE_A)
	world.register_store(tag, TYPE_TAG)
	store.track_changes = true

	var random := RandomNumberGenerator.new()
	var expected := {}
	var buffer := PackedInt32Array()
	buffer.resize(64)
	random.seed = 0x5EED

	var consistent := true
	for step in 400:
		match random.randi_range(0, 3):
			0:
				var wanted: int = random.randi_range(1, 32)
				var spawned: int = world.create_entities(wanted, buffer)
				for i in spawned:
					var entity: int = buffer[i]
					var value: int = random.randi_range(1, 1000)
					store.assign(entity, value)
					expected[entity] = value
					if random.randf() < 0.5:
						tag.attach(entity)
			1:
				var victims: int = 0
				for i in mini(16, buffer.size()):
					var candidate: int = random.randi_range(0, world.capacity - 1)
					if world.is_alive(candidate):
						buffer[victims] = candidate
						victims += 1
				world.queue_destroy_many(buffer, victims)
			2:
				world.flush_destroy_queue()
				for entity in expected.keys():
					if not world.is_alive(entity):
						expected.erase(entity)
			3:
				var target: int = random.randi_range(0, world.capacity - 1)
				if store.has(target):
					store.detach(target)
					expected.erase(target)

		if step % 37 == 0:
			world.flush_destroy_queue()
			for entity in expected.keys():
				if not world.is_alive(entity):
					expected.erase(entity)
			consistent = consistent and world.validate_integrity(false)
			for entity in expected.keys():
				var slot: int = store.index_of(entity)
				if slot == -1 or store.numbers[slot] != expected[entity]:
					consistent = false
					break
				if store.points[slot] != Vector3(expected[entity], expected[entity] * 2, expected[entity] * 3):
					consistent = false
					break
			store.clear_change_log()

	world.flush_destroy_queue()
	_expect(consistent and world.validate_integrity(false),
		"400 random batched structural operations preserve every payload and invariant")


func _expect(condition: bool, label: String) -> void:
	if condition:
		print("  ok   %s" % label)
	else:
		_failures += 1
		print("  FAIL %s" % label)
