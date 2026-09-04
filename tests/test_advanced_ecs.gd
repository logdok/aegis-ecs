extends SceneTree

const TYPE_POSITION: int = 0
const TYPE_VELOCITY: int = 1
const TYPE_DISABLED: int = 2

var _failures: int = 0


class ScalarStore extends EcsComponentStore:
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


class ReferenceStore extends EcsComponentStore:
	var values: Array[RefCounted] = []
	var owned_ids: PackedInt32Array = PackedInt32Array()
	var released_ids: PackedInt32Array = PackedInt32Array()

	func _reserve_dense(dense_capacity: int) -> void:
		values.resize(dense_capacity)
		owned_ids.resize(dense_capacity)

	func _grow_dense(_previous_capacity: int, dense_capacity: int) -> void:
		values.resize(dense_capacity)
		owned_ids.resize(dense_capacity)

	func _relocate_dense(from_slot: int, to_slot: int) -> void:
		values[to_slot] = values[from_slot]
		owned_ids[to_slot] = owned_ids[from_slot]

	func _release_dense(dense_slot: int) -> void:
		if owned_ids[dense_slot] != 0:
			released_ids.append(owned_ids[dense_slot])
		values[dense_slot] = null
		owned_ids[dense_slot] = 0

	func _clear_relocated_dense(dense_slot: int) -> void:
		values[dense_slot] = null
		owned_ids[dense_slot] = 0

	func _clear_dense(active_count: int) -> void:
		for index in active_count:
			if owned_ids[index] != 0:
				released_ids.append(owned_ids[index])
			values[index] = null
			owned_ids[index] = 0


class PipelineContext:
	var order: Array[String] = []


class RecordingSystem extends EcsSystem:
	var marker: String
	var _context: PipelineContext

	func _init(label: String) -> void:
		marker = label
		system_name = label

	func setup(_world: EcsWorld, context) -> void:
		_context = context

	func execute(delta: float) -> void:
		_context.order.append("%s:%.1f" % [marker, delta])

	func teardown() -> void:
		_context.order.append("down:%s" % marker)


func _init() -> void:
	print("=== Aegis ECS: advanced tests ===")
	_test_generational_handles()
	_test_capacity_growth_and_cleanup()
	_test_view_and_query()
	_test_scheduler_controls_and_metadata()
	_test_structural_fuzz()
	print("RESULT: %s" % ("OK" if _failures == 0 else "FAILED (%d)" % _failures))
	quit(0 if _failures == 0 else 1)


func _test_generational_handles() -> void:
	var world := EcsWorld.new(1)
	var store := ScalarStore.new()
	_expect(world.register_store(store, TYPE_POSITION), "store registration succeeds")
	_expect(store.is_initialized(), "store tracks initialization independently of type id")
	var first: int = world.create_entity()
	store.assign(first, 10)
	var old_handle: int = world.make_handle(first)
	_expect(old_handle > 0 and world.entity_from_handle(old_handle) == first, "handle resolves in its world")
	_expect(world.queue_destroy_handle(old_handle), "first handle destroy is queued")
	_expect(world.is_handle_alive(old_handle) and world.is_handle_pending_destroy(old_handle), "pending handle remains valid until flush")
	_expect(not world.queue_destroy_handle(old_handle), "duplicate handle destroy is rejected")
	_expect(world.flush_destroy_queue() == 1 and not world.is_handle_alive(old_handle), "flush invalidates handle")
	_expect(store.count == 0, "flush detaches components")
	store.detach(-1)
	_expect(store.count == 0, "invalid structural detach cannot use negative indexing")

	var second: int = world.create_entity()
	var new_handle: int = world.make_handle(second)
	_expect(second == first and new_handle != old_handle, "reused raw id gets a new generation")
	_expect(world.entity_from_handle(old_handle) == EcsWorld.INVALID_ENTITY, "stale handle cannot resolve after ABA")
	_expect(not world.queue_destroy_handle(old_handle) and world.is_alive(second), "stale handle cannot destroy new occupant")

	var other_world := EcsWorld.new(1)
	_expect(other_world.entity_from_handle(new_handle) == EcsWorld.INVALID_ENTITY, "cross-world handle is rejected")
	world.reset()
	_expect(not world.is_handle_alive(new_handle), "reset invalidates live handles")
	_expect(world.validate_integrity(false), "world invariants hold after handle lifecycle")

	var overflow_world := EcsWorld.new(1)
	var overflow_entity: int = overflow_world.create_entity()
	overflow_world._generations[overflow_entity] = 0xFFFFFF
	var final_handle: int = overflow_world.make_handle(overflow_entity)
	overflow_world.queue_destroy_handle(final_handle)
	overflow_world.flush_destroy_queue()
	_expect(overflow_world.get_retired_count() == 1 and overflow_world.create_entity() == -1,
		"generation overflow retires slot instead of wrapping")
	overflow_world.reset()
	overflow_world.reserve_capacity(2)
	_expect(overflow_world.get_retired_count() == 1 and overflow_world.get_free_count() == 1,
		"retired slot survives reset and explicit growth")
	_expect(overflow_world.validate_integrity(false), "retired slot preserves allocator invariants")

	var tagless_world := EcsWorld.new(2)
	tagless_world._world_tag = 0
	_expect(tagless_world.create_entity_handle() == EcsWorld.INVALID_HANDLE \
		and tagless_world.get_live_count() == 0, "unavailable world tag does not consume handle capacity")
	var tagless_entity: int = tagless_world.create_entity()
	tagless_world.queue_destroy(tagless_entity)
	tagless_world.flush_destroy_queue()
	_expect(tagless_world.get_live_count() == 0 and tagless_world.validate_integrity(false),
		"raw lifecycle remains valid without public handle tag")


func _test_capacity_growth_and_cleanup() -> void:
	var world := EcsWorld.new(2)
	var store := ReferenceStore.new()
	world.register_store(store, TYPE_POSITION)
	var first: int = world.create_entity()
	var second: int = world.create_entity()
	store.attach(first)
	store.attach(second)
	store.values[0] = RefCounted.new()
	store.values[1] = RefCounted.new()
	store.owned_ids[0] = 10
	store.owned_ids[1] = 20
	var first_handle: int = world.make_handle(first)
	_expect(world.reserve_capacity(5), "capacity grows at an explicit barrier")
	_expect(world.capacity == 5 and store.get_capacity() == 5, "world and store grow together")
	_expect(world.is_handle_alive(first_handle), "capacity growth preserves handles")
	world.queue_destroy(first)
	world.flush_destroy_queue()
	_expect(store.released_ids == PackedInt32Array([10]), "detach releases removed ownership, not moved payload")
	_expect(store.owned_ids[0] == 20 and store.values[store.count] == null,
		"relocation transfers ownership and clears moved-from slot")
	world.reset()
	var references_cleared := true
	for value in store.values:
		references_cleared = references_cleared and value == null
	_expect(references_cleared, "reset clears reference-bearing payload")
	_expect(store.released_ids == PackedInt32Array([10, 20]), "reset releases remaining ownership exactly once")
	_expect(world.get_free_count() == 5 and world.validate_integrity(false), "grown allocator remains consistent")

	var pending_world := EcsWorld.new(1)
	var pending_store := ScalarStore.new()
	pending_world.register_store(pending_store, TYPE_POSITION)
	var pending_entity: int = pending_world.create_entity()
	pending_store.assign(pending_entity, 7)
	pending_world.queue_destroy(pending_entity)
	_expect(pending_world.reserve_capacity(2) and pending_world.flush_destroy_queue() == 1,
		"pending destroy queue survives capacity growth")
	_expect(pending_world.validate_integrity(false), "growth with pending destroy preserves invariants")


func _test_view_and_query() -> void:
	var world := EcsWorld.new(16)
	var positions := ScalarStore.new()
	var velocities := ScalarStore.new()
	var disabled := EcsTagStore.new()
	world.register_store(positions, TYPE_POSITION)
	world.register_store(velocities, TYPE_VELOCITY)
	world.register_store(disabled, TYPE_DISABLED)
	var entities := PackedInt32Array()
	for index in 8:
		var entity: int = world.create_entity()
		entities.append(entity)
		positions.assign(entity, index)
		if index % 2 == 0:
			velocities.assign(entity, index * 10)
	disabled.attach(entities[2])

	var owner := RecordingSystem.new("ViewOwner")
	owner.declare_read(TYPE_POSITION).declare_read(TYPE_VELOCITY).declare_read(TYPE_DISABLED).complete_access_metadata()
	var view := EcsView.new()
	_expect(view.configure(
		world,
		PackedInt32Array([TYPE_POSITION, TYPE_VELOCITY]),
		PackedInt32Array([TYPE_DISABLED]),
		owner,
	), "view configures required/excluded stores")
	view.refresh_driver()
	_expect(view.get_candidate_store() == velocities and view.get_candidate_count() == 4, "view selects smallest required store")
	_expect(view.validate_owner_access(false), "view access matches system metadata")

	var query := EcsQuery.new()
	_expect(query.configure(
		world,
		PackedInt32Array([TYPE_POSITION, TYPE_VELOCITY]),
		PackedInt32Array([TYPE_DISABLED]),
		owner,
	), "query configures from component types")
	_expect(query.refresh() and query.count == 3, "query materializes correct intersection")
	_expect(not query.refresh() and query.get_rebuild_count() == 1, "unchanged query skips rebuild")
	positions.values[0] += 1
	_expect(not query.refresh(), "payload write does not invalidate membership cache")

	var version_before: int = velocities.structural_version
	velocities.attach(entities[0])
	velocities.detach(entities[1])
	_expect(velocities.structural_version == version_before, "no-op attach/detach keep structural version")
	disabled.attach(entities[4])
	_expect(query.refresh() and query.count == 2, "tag attach invalidates cached query")
	disabled.detach(entities[2])
	_expect(query.refresh() and query.count == 3, "tag detach invalidates cached query")
	world.reserve_capacity(24)
	_expect(query.refresh() and query.count == 3, "query adapts at explicit capacity growth barrier")
	var limited_query := EcsQuery.new()
	limited_query.configure(
		world,
		PackedInt32Array([TYPE_POSITION, TYPE_VELOCITY]),
		PackedInt32Array(),
		owner,
		2,
	)
	limited_query.refresh()
	_expect(limited_query.count == 2 and limited_query.is_truncated(),
		"query result cap bounds memory and reports truncation")
	velocities.detach(entities[4])
	velocities.detach(entities[6])
	limited_query.refresh()
	query.refresh()
	_expect(limited_query.count == 2 and not limited_query.is_truncated(),
		"query clears truncation when the result fits again")

	var results_valid := true
	for index in query.count:
		var entity: int = query.entity_at(index)
		results_valid = results_valid \
			and positions.has(entity) and velocities.has(entity) and not disabled.has(entity)
	_expect(results_valid and world.validate_integrity(false), "query results and sparse sets remain valid")


func _test_scheduler_controls_and_metadata() -> void:
	var world := EcsWorld.new(2)
	world.register_store(ScalarStore.new(), TYPE_POSITION)
	world.register_store(ScalarStore.new(), TYPE_VELOCITY)
	var context := PipelineContext.new()
	var first := RecordingSystem.new("First")
	var second := RecordingSystem.new("Second")
	var third := RecordingSystem.new("Third")
	first.declare_read(TYPE_POSITION)
	second.declare_write(TYPE_POSITION)
	third.declare_read(TYPE_VELOCITY)
	first.complete_access_metadata()
	second.complete_access_metadata()
	third.complete_access_metadata()
	var scheduler := EcsScheduler.new()
	scheduler.add_system(first, 100)
	scheduler.add_system(second, 200)
	scheduler.add_system(third, 200)
	_expect(scheduler.setup_all(world, context), "scheduler setup succeeds once")
	_expect(scheduler.validate_pipeline(world, false), "scheduler phases and metadata validate")
	_expect(scheduler.systems_conflict(0, 1), "read/write dependency is detected")
	_expect(not scheduler.systems_conflict(1, 2), "independent component access has no conflict")
	var unknown := RecordingSystem.new("UnknownAccess")
	var known := RecordingSystem.new("KnownAccess")
	known.declare_read(TYPE_VELOCITY).complete_access_metadata()
	var conservative := EcsScheduler.new()
	conservative.add_system(unknown)
	conservative.add_system(known)
	_expect(conservative.systems_conflict(0, 1),
		"incomplete legacy metadata conflicts conservatively")
	var world_writer := RecordingSystem.new("WorldWriter")
	var idle := RecordingSystem.new("NoWorldAccess")
	world_writer.writes_world_structure = true
	world_writer.complete_access_metadata()
	idle.complete_access_metadata()
	var world_conflicts := EcsScheduler.new()
	world_conflicts.add_system(world_writer)
	world_conflicts.add_system(idle)
	_expect(world_conflicts.systems_conflict(0, 1),
		"world lifecycle writes conflict with every system")
	var invalid_order := EcsScheduler.new()
	invalid_order.add_system(RecordingSystem.new("Late"), 200)
	invalid_order.add_system(RecordingSystem.new("Early"), 100)
	_expect(not invalid_order.validate_pipeline(world, false), "phase regression is detected without auto-sort")

	scheduler.execute_all(0.5)
	_expect(context.order == ["First:0.5", "Second:0.5", "Third:0.5"], "registration order remains execution order")
	scheduler.set_system_enabled(1, false)
	context.order.clear()
	scheduler.execute_all(0.0)
	_expect(context.order == ["First:0.0", "Third:0.0"], "system switch preserves delta-zero contract")
	_expect(not scheduler.was_system_executed(1) and scheduler.get_timing_usec(1) == 0.0, "disabled system reports no stale timing")

	scheduler.set_system_enabled(1, true)
	scheduler.set_phase_enabled(200, false)
	context.order.clear()
	scheduler.execute_all(1.0)
	_expect(context.order == ["First:1.0"], "phase switch skips a complete group")
	scheduler.set_phase_enabled(200, true)
	context.order.clear()
	scheduler.begin_frame()
	scheduler.execute_phase(100, 0.25)
	scheduler.execute_phase(200, 0.25)
	_expect(context.order == ["First:0.2", "Second:0.2", "Third:0.2"], "phases execute explicitly without reordering")

	scheduler.set_phase_enabled(100, false)
	scheduler.set_system_phase(0, 200)
	context.order.clear()
	scheduler.execute_all(0.75)
	_expect(scheduler.get_system_phase(0) == 200 \
		and context.order == ["First:0.8", "Second:0.8", "Third:0.8"],
		"scheduler phase mutation adopts the destination phase state")

	context.order.clear()
	scheduler.teardown_all()
	_expect(context.order == ["down:Third", "down:Second", "down:First"], "teardown runs in reverse order")


func _test_structural_fuzz() -> void:
	var corrupt_world := EcsWorld.new(2)
	var corrupt_store := ScalarStore.new()
	corrupt_world.register_store(corrupt_store, TYPE_POSITION)
	corrupt_store.count = 3
	corrupt_store.sparse_index[0] = 2
	_expect(not corrupt_store.validate_integrity(PackedByteArray(), false),
		"store validator reports corrupt count/slot without out-of-bounds access")

	var world := EcsWorld.new(128)
	var store := ScalarStore.new()
	world.register_store(store, TYPE_POSITION)
	var random := RandomNumberGenerator.new()
	random.seed = 0xAE615
	var valid := true
	for step in 5000:
		var operation: int = random.randi_range(0, 4)
		if operation <= 1:
			var entity: int = world.create_entity()
			if entity >= 0:
				store.assign(entity, step)
		elif operation <= 3:
			world.queue_destroy(random.randi_range(0, world.capacity - 1))
		else:
			world.flush_destroy_queue()
		if step % 97 == 0:
			world.flush_destroy_queue()
			valid = valid and world.validate_integrity(false)
	world.flush_destroy_queue()
	_expect(valid and world.validate_integrity(false), "5k random structural operations preserve invariants")


func _expect(condition: bool, label: String) -> void:
	if condition:
		print("  ok   %s" % label)
	else:
		_failures += 1
		print("  FAIL %s" % label)
