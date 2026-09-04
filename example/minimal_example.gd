extends SceneTree

## A minimal but COMPLETE Aegis ECS example — and at the same time an add-on
## self-check.
##
## Run from the root of a project that contains the add-on:
##   godot --headless --script res://addons/aegis_ecs/example/minimal_example.gd
##
## It shows everything needed to get started:
##   1. declaring a component store with no boilerplate (EcsPackedStore);
##   2. declaring a system and accessing data through your own context;
##   3. assembling the world and the order in which everything is registered;
##   4. the "destruction happens at exactly one point" rule (EcsReaperSystem);
##   5. batched spawning;
##   6. reading the built-in profiler.
##
## The classes here are declared INNER (`class ... extends ...`), not with
## `class_name`, so the example adds nothing to your project's global namespace.


# --- 1. Component stores ---------------------------------------------------

## Component data lives in parallel Packed arrays addressed by a dense slot.
## Extending EcsPackedStore means declaring the fields and naming them once:
## memory allocation, growth and swap-remove relocation are done for you.
##
## (The lower-level EcsComponentStore is still there — if a store needs full
## manual control; then it must implement _reserve_dense and _relocate_dense
## itself, and a forgotten second one silently corrupts data on removal.)
class PositionStore extends EcsPackedStore:
	var x: PackedFloat32Array = PackedFloat32Array()
	var y: PackedFloat32Array = PackedFloat32Array()

	func _init() -> void:
		track(&"x", &"y")

	## A convenience wrapper: attach the component and fill it in one call.
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


# --- 2. Your context -----------------------------------------------------

## The library knows nothing about your game: it just hands this object to every
## system in setup(). Keep references to stores and shared state here, so systems
## never have to know about each other directly.
class Context:
	var world: EcsWorld
	var positions: PositionStore
	var velocities: VelocityStore
	var alive_tag: EcsTagStore
	var escaped_count: int = 0


# --- 3. Systems --------------------------------------------------------

## Integrates velocity into position. Note the iteration: walk the DENSE array of
## the smaller store and fetch the second component through the sparse index.
## This is the fastest API level; EcsView and EcsQuery cover the cases where the
## component set changes.
class MovementSystem extends EcsSystem:
	var _context: Context

	func _init() -> void:
		system_name = "Movement"
		# While time is stopped there is nothing to do, so let the scheduler skip
		# the call entirely rather than opening execute() with an early return.
		requires_time = true
		declare_read(TYPE_VELOCITY).declare_write(TYPE_POSITION).complete_access_metadata()

	func setup(_world: EcsWorld, context) -> void:
		_context = context

	func execute(delta: float) -> void:
		var positions: PositionStore = _context.positions
		var velocities: VelocityStore = _context.velocities

		# Local aliases of the Packed arrays: reading a local variable in the
		# loop is noticeably cheaper than an object field on every iteration.
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

		# In Godot 4 the Packed arrays are passed by reference: the local aliases
		# already wrote into the store. No assignment back is needed.


## Queues everyone who has left the arena for destruction.
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
				# Only MARKS. The entity lives until the end of the frame, so this
				# dense iteration does not fall apart under our feet.
				world.queue_destroy(owners[dense])
				_context.escaped_count += 1


# --- 4. Assembly and run ---------------------------------------------

const TYPE_POSITION: int = 0
const TYPE_VELOCITY: int = 1
const TYPE_ALIVE: int = 2

const POPULATION: int = 500

var _failures: int = 0


func _init() -> void:
	print("=== Aegis ECS: minimal example ===")

	var context := Context.new()
	context.world = EcsWorld.new(1000)

	# Stores: create, then register. Registration allocates their internal arrays
	# for the world's capacity and must happen before the first entity.
	context.positions = PositionStore.new()
	context.velocities = VelocityStore.new()
	context.alive_tag = EcsTagStore.new()
	context.world.register_store(context.positions, TYPE_POSITION)
	context.world.register_store(context.velocities, TYPE_VELOCITY)
	context.world.register_store(context.alive_tag, TYPE_ALIVE)

	# Registration order = execution order = behaviour. Movement must run before
	# the bounds check, and destruction last.
	var scheduler := EcsScheduler.new()
	scheduler.add_system(MovementSystem.new())
	scheduler.add_system(BoundsSystem.new(100.0))
	scheduler.add_system(EcsReaperSystem.new(context.world))
	scheduler.setup_all(context.world, context)
	_expect(scheduler.validate_pipeline(context.world), "the pipeline validates")

	# Batched spawn: one call instead of POPULATION calls. The identifiers land
	# in a reusable buffer, and attach_many() gives the components contiguous slots.
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

	# Frames: in 10 seconds of model time everyone gets across the boundary.
	for frame in 600:
		scheduler.execute_all(1.0 / 60.0)

	print("still alive: %d, escaped: %d" % [context.world.get_live_count(), context.escaped_count])
	_expect(context.escaped_count > 0, "some entities left the arena")
	_expect(context.world.get_live_count() + context.escaped_count == POPULATION,
		"the entity balance adds up")
	_expect(context.positions.count == context.world.get_live_count(),
		"the store agrees with the world after destruction")

	# Pause: a zero-length step must change nothing.
	var before: int = context.world.get_live_count()
	scheduler.execute_all(0.0)
	_expect(context.world.get_live_count() == before, "a zero-length step changed nothing")

	# Resetting the world reuses every already allocated byte.
	context.world.reset()
	_expect(context.world.get_live_count() == 0, "reset() emptied the world")
	_expect(context.positions.count == 0, "reset() emptied the stores")

	# Looking a store up by type — for assembly and debugging, not for hot loops.
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
