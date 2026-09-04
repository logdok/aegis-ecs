extends SceneTree

## Reproducible micro-benchmarks of the paths that determine a real frame.
##
## Run from a project that contains the add-on:
##   godot --headless --script res://addons/aegis_ecs/tests/benchmark_ecs.gd
##
## The numbers are the best of N runs, to dampen OS noise, and are useful as
## RATIOS rather than as an absolute guarantee: on a mobile device expect several
## times slower. The point of keeping this in the repository is that an
## optimization can be proven rather than assumed, and a regression shows up as a
## number.

const ENTITIES: int = 10000
const STORES: int = 12
const REPEATS: int = 5


## A hand-written store: the classic form, two mandatory overrides.
class ManualStore extends EcsComponentStore:
	var values: PackedFloat32Array = PackedFloat32Array()
	var vectors: PackedVector3Array = PackedVector3Array()

	func _reserve_dense(dense_capacity: int) -> void:
		values.resize(dense_capacity)
		vectors.resize(dense_capacity)

	func _grow_dense(_previous_capacity: int, dense_capacity: int) -> void:
		values.resize(dense_capacity)
		vectors.resize(dense_capacity)

	func _relocate_dense(from_slot: int, to_slot: int) -> void:
		values[to_slot] = values[from_slot]
		vectors[to_slot] = vectors[from_slot]


## Does nothing: the point is to measure the observer, not the systems.
class NoopSystem extends EcsSystem:
	func _init(display_name: String) -> void:
		system_name = display_name
		complete_access_metadata()


## The same data in declarative form: not a single override.
class DeclarativeStore extends EcsPackedStore:
	var values: PackedFloat32Array = PackedFloat32Array()
	var vectors: PackedVector3Array = PackedVector3Array()

	func _init() -> void:
		track(&"values", &"vectors")


func _init() -> void:
	print("=== Aegis ECS benchmarks (Godot %s) ===" % Engine.get_version_info().string)
	print("  %d entities, best of %d\n" % [ENTITIES, REPEATS])
	_bench_destroy_uniform()
	_bench_destroy_mixed()
	_bench_store_flavours()
	_bench_spawn()
	_bench_iteration()
	_bench_query()
	_bench_grid()
	_bench_observer()
	quit(0)


# --- destruction ------------------------------------------------------------

## All stores are the same size, so each one walks the list of victims.
func _bench_destroy_uniform() -> void:
	print("-- destruction, %d equally sized stores --" % STORES)
	for owned in [4, 12]:
		var samples := PackedFloat64Array()
		for repeat in REPEATS:
			var world := EcsWorld.new(ENTITIES)
			var stores: Array[ManualStore] = []
			for s in STORES:
				var store := ManualStore.new()
				world.register_store(store, s)
				stores.append(store)
			for i in ENTITIES:
				var entity: int = world.create_entity()
				for s in owned:
					stores[s].attach(entity)
			for i in ENTITIES:
				world.queue_destroy(i)
			var started: int = Time.get_ticks_usec()
			world.flush_destroy_queue()
			samples.append(float(Time.get_ticks_usec() - started))
		_report("flush %dk entities, %d of %d components each"
			% [ENTITIES / 1000, owned, STORES], _best(samples))


## A realistic shape: a few large stores plus many small specialized ones. Each
## small one should cost O(its own size), not O(victims).
func _bench_destroy_mixed() -> void:
	print("\n-- destruction, mixed store sizes (2 large + 10 small) --")
	var samples := PackedFloat64Array()
	for repeat in REPEATS:
		var world := EcsWorld.new(ENTITIES)
		var large: Array[ManualStore] = []
		var small: Array[ManualStore] = []
		for s in 2:
			var store := ManualStore.new()
			world.register_store(store, s)
			large.append(store)
		for s in range(2, STORES):
			var store := ManualStore.new()
			world.register_store(store, s)
			small.append(store)
		for i in ENTITIES:
			var entity: int = world.create_entity()
			for store in large:
				store.attach(entity)
			if i < 32:
				for store in small:
					store.attach(entity)
		for i in ENTITIES:
			world.queue_destroy(i)
		var started: int = Time.get_ticks_usec()
		world.flush_destroy_queue()
		samples.append(float(Time.get_ticks_usec() - started))
	_report("flush %dk entities, 10 stores hold only 32 each" % (ENTITIES / 1000), _best(samples))


## Hand-written vs declarative, the data is identical.
func _bench_store_flavours() -> void:
	print("\n-- hand-written EcsComponentStore vs declarative EcsPackedStore --")
	for declarative in [false, true]:
		var samples := PackedFloat64Array()
		for repeat in REPEATS:
			var world := EcsWorld.new(ENTITIES)
			var stores: Array[EcsComponentStore] = []
			for s in 4:
				var store: EcsComponentStore = DeclarativeStore.new() if declarative else ManualStore.new()
				world.register_store(store, s)
				stores.append(store)
			for i in ENTITIES:
				var entity: int = world.create_entity()
				for store in stores:
					store.attach(entity)
			for i in ENTITIES:
				world.queue_destroy(i)
			var started: int = Time.get_ticks_usec()
			world.flush_destroy_queue()
			samples.append(float(Time.get_ticks_usec() - started))
		_report("flush %dk x 4 stores (%s)"
			% [ENTITIES / 1000, "declarative" if declarative else "hand-written"], _best(samples))


# --- creation --------------------------------------------------------------

func _bench_spawn() -> void:
	print("\n-- creation --")
	var samples := PackedFloat64Array()
	for repeat in REPEATS:
		var world := EcsWorld.new(ENTITIES)
		var store := ManualStore.new()
		world.register_store(store, 0)
		var started: int = Time.get_ticks_usec()
		for i in ENTITIES:
			var entity: int = world.create_entity()
			if entity >= 0:
				store.attach(entity)
		samples.append(float(Time.get_ticks_usec() - started))
	_report("create_entity + attach, one at a time", _best(samples))

	samples.resize(0)
	var buffer := PackedInt32Array()
	buffer.resize(ENTITIES)
	for repeat in REPEATS:
		var world := EcsWorld.new(ENTITIES)
		var store := ManualStore.new()
		world.register_store(store, 0)
		var started: int = Time.get_ticks_usec()
		var spawned: int = world.create_entities(ENTITIES, buffer)
		store.attach_many(buffer, spawned)
		samples.append(float(Time.get_ticks_usec() - started))
	_report("create_entities + attach_many, batched", _best(samples))


# --- iteration ------------------------------------------------------------

func _bench_iteration() -> void:
	print("\n-- iteration --")
	var world := EcsWorld.new(ENTITIES)
	var a := ManualStore.new()
	var b := ManualStore.new()
	world.register_store(a, 0)
	world.register_store(b, 1)
	for i in ENTITIES:
		var entity: int = world.create_entity()
		a.attach(entity)
		b.attach(entity)

	var samples := PackedFloat64Array()
	for repeat in REPEATS:
		var started: int = Time.get_ticks_usec()
		var av: PackedFloat32Array = a.values
		var bv: PackedFloat32Array = b.values
		var owners: PackedInt32Array = a.dense_entities
		var b_slots: PackedInt32Array = b.sparse_index
		for dense in a.count:
			var slot: int = b_slots[owners[dense]]
			if slot < 0:
				continue
			av[dense] += bv[slot]
		samples.append(float(Time.get_ticks_usec() - started))
	_report("joined dense loop over %dk" % (ENTITIES / 1000), _best(samples))


func _bench_query() -> void:
	print("\n-- EcsQuery --")
	var world := EcsWorld.new(ENTITIES)
	var a := ManualStore.new()
	var b := ManualStore.new()
	var c := EcsTagStore.new()
	world.register_store(a, 0)
	world.register_store(b, 1)
	world.register_store(c, 2)
	for i in ENTITIES:
		var entity: int = world.create_entity()
		a.attach(entity)
		b.attach(entity)
		if i % 5 == 0:
			c.attach(entity)

	var query := EcsQuery.new()
	query.configure(world, PackedInt32Array([0, 1]), PackedInt32Array([2]))
	var samples := PackedFloat64Array()
	for repeat in REPEATS:
		var started: int = Time.get_ticks_usec()
		for frame in 10:
			# Force a rebuild every time: a real frame changes the membership.
			a.detach(a.dense_entities[a.count - 1])
			query.refresh()
		samples.append(float(Time.get_ticks_usec() - started))
	_report("refresh x10, 2 required + 1 excluded over %dk" % (ENTITIES / 1000), _best(samples))

	samples.resize(0)
	for repeat in REPEATS:
		var started: int = Time.get_ticks_usec()
		for frame in 10:
			query.refresh()
		samples.append(float(Time.get_ticks_usec() - started))
	_report("refresh x10, membership unchanged (cache hit)", _best(samples))


# --- spatial grid ----------------------------------------------------------

func _bench_grid() -> void:
	print("\n-- UniformSpatialGrid --")
	var rng := RandomNumberGenerator.new()
	rng.seed = 12345
	var ids := PackedInt32Array()
	var points := PackedVector3Array()
	ids.resize(ENTITIES)
	points.resize(ENTITIES)
	for i in ENTITIES:
		ids[i] = i
		points[i] = Vector3(rng.randf_range(-130.0, 130.0), rng.randf_range(0.0, 4.0), rng.randf_range(-130.0, 130.0))

	var suggested: float = UniformSpatialGrid.suggest_cell_size(130.0, 0.0, ENTITIES, 12.0)
	print("  suggest_cell_size(r=130, flat, n=%d, query_r=12) -> %.2f" % [ENTITIES, suggested])

	for flat in [false, true]:
		var grid := UniformSpatialGrid.new()
		grid.configure(130.0, 0.0 if flat else 24.0, 6.0, ENTITIES)
		var label: String = "flat 2D" if flat else "full 3D"
		var samples := PackedFloat64Array()
		for repeat in REPEATS:
			var started: int = Time.get_ticks_usec()
			grid.rebuild(ids, points, ENTITIES)
			samples.append(float(Time.get_ticks_usec() - started))
		_report("rebuild %dk, cell=6, %s (%d cells)"
			% [ENTITIES / 1000, label, grid.get_cell_count()], _best(samples))

		samples.resize(0)
		for repeat in REPEATS:
			var started: int = Time.get_ticks_usec()
			for q in 512:
				grid.query_nearest(points[q * 7], 12.0)
			samples.append(float(Time.get_ticks_usec() - started))
		_report("query_nearest x512, %s" % label, _best(samples))


# --- observer cost -------------------------------------------------------

## What observing costs. Recording runs every frame, so it must be negligible;
## analysis runs a few times a second, so it only has to be small. Both are
## measured here, not assumed.
func _bench_observer() -> void:
	print("\n-- inspector overhead (20 systems) --")
	var world := EcsWorld.new(1024)
	var store := ManualStore.new()
	world.register_store(store, 0)
	var scheduler := EcsScheduler.new()
	for i in 20:
		scheduler.add_system(NoopSystem.new("System%02d" % i))
	scheduler.setup_all(world, null)
	for i in 256:
		var entity: int = world.create_entity()
		if entity >= 0:
			store.attach(entity)

	var recorder := EcsFrameRecorder.new()
	recorder.configure(scheduler, world, 240)
	for frame in 240:
		scheduler.execute_all(1.0 / 60.0)
		recorder.capture()

	var samples := PackedFloat64Array()
	for repeat in REPEATS:
		var started: int = Time.get_ticks_usec()
		for i in 2000:
			recorder.capture()
		samples.append(float(Time.get_ticks_usec() - started) / 2000.0)
	var capture_cost: float = _best(samples)
	print("  %-52s %9.2f us/frame  (%.4f%% of 16.6 ms)"
		% ["recorder.capture(), every frame", capture_cost, capture_cost / 16600.0 * 100.0])

	var stats := EcsFrameStats.new()
	samples.resize(0)
	for repeat in REPEATS:
		var started: int = Time.get_ticks_usec()
		for i in 100:
			stats.analyse(recorder)
		samples.append(float(Time.get_ticks_usec() - started) / 100.0)
	var analyse_cost: float = _best(samples)
	print("  %-52s %9.2f us  (%.3f%% of a frame at 2 Hz)"
		% ["stats.analyse(), a few times a second", analyse_cost, analyse_cost / 30.0 / 16600.0 * 100.0])

	var diagnostics := EcsDiagnostics.new()
	samples.resize(0)
	for repeat in REPEATS:
		var started: int = Time.get_ticks_usec()
		for i in 100:
			diagnostics.inspect(recorder, stats, world)
		samples.append(float(Time.get_ticks_usec() - started) / 100.0)
	print("  %-52s %9.2f us" % ["diagnostics.inspect(), twice a second", _best(samples)])
	print("  %-52s %9.1f KB" % ["window memory, 240 frames x 20 systems",
		recorder.get_memory_usage() / 1024.0])


# --- helpers ------------------------------------------------------------

func _best(samples: PackedFloat64Array) -> float:
	var best: float = samples[0]
	for sample in samples:
		if sample < best:
			best = sample
	return best


func _report(label: String, usec: float) -> void:
	print("  %-52s %9.2f ms" % [label, usec / 1000.0])
