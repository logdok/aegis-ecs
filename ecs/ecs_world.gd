class_name EcsWorld
extends RefCounted

## The entity allocator and the component store registry.
##
## An entity here is NOT an object or a class, just an integer (an index). An
## entity on its own holds no data: the data lives in component stores
## ([EcsComponentStore]), and the entity is only a key those stores are indexed
## by. That is the essence of ECS: Entity is just an id, Component is pure data,
## System is pure logic over that data. Game objects in this approach are not
## Godot nodes: the whole simulation runs over flat arrays.
##
## The world does not grow on its own: the capacity is fixed at creation, and a
## rare explicit growth happens only through [method reserve_capacity] at a
## loading barrier. Between such barriers the internal arrays are reused with no
## allocations. This is a deliberate decision: a hidden allocation in the hot
## loop with tens of thousands of entities causes frame spikes on a weak mobile
## device.
##
## [b]THE DESTRUCTION MODEL IS THE MOST IMPORTANT THING IN THIS FILE.[/b]
## Nothing is ever destroyed "in place", right at the moment of the call. Any
## code that wants to kill an entity calls [method queue_destroy] — that only
## MARKS it and does not touch data. The real removal is done by
## [method flush_destroy_queue], and it must run at ONE known point in the frame
## — usually from the last system in the pipeline (see [EcsReaperSystem], which
## exists precisely so you do not have to write that system yourself).
##
## Why this way? If destruction were instant, the following could happen within a
## single frame: system A read entity E and is holding its dense slot, then
## system B destroyed E, and that slot went, via swap-remove, to ANOTHER entity
## (see [EcsComponentStore]). System A would read data that now belongs to
## someone else — a classic use-after-free, except nothing crashes: the data is
## just silently wrong. Deferring destruction to one point in the frame rules
## this scenario out completely: no dense slot obtained at the start of a frame
## can go stale before its end.
##
## In hot loops an entity stays a raw int, so arrays are indexed with no decoding
## and no generation check. For references that survive across a frame (a target,
## an owner, a callback), use the generational handle from [method make_handle]
## or [method create_entity_handle]. After an entity is destroyed and the same
## raw id is handed out again, an old handle is guaranteed not to resolve.
##
## [method flush_destroy_queue] is a structural sync point. It can sit at several
## explicitly defined phase boundaries, but only where no system is holding a
## dense slot: swap-remove may move another component.

const INVALID_ENTITY: int = -1
const INVALID_HANDLE: int = 0
const _HANDLE_ENTITY_MASK: int = 0xFFFFFF
const _HANDLE_GENERATION_MASK: int = 0xFFFFFF
const _HANDLE_WORLD_MASK: int = 0x7FFF
const _HANDLE_GENERATION_SHIFT: int = 24
const _HANDLE_WORLD_SHIFT: int = 48

static var _next_world_tag: int = 1

var capacity: int = 0

var _alive: PackedByteArray = PackedByteArray()
var _free_ids: PackedInt32Array = PackedInt32Array()
var _free_count: int = 0
var _live_count: int = 0

var _stores: Array[EcsComponentStore] = []
var _stores_by_type: Dictionary = {}
var _schema_locked: bool = false

# The destroy queue keeps a generation stamp next to the raw id, so a stale entry
# cannot resurrect an already reused slot. Splitting it into two Int32 arrays
# (instead of one packed Int64 key) costs the same memory and lets
# flush_destroy_queue() compact the resolved victims in place, with no scratch
# array.
var _destroy_queue: PackedInt32Array = PackedInt32Array()
var _destroy_generation: PackedInt32Array = PackedInt32Array()
var _destroy_flag: PackedByteArray = PackedByteArray()
var _destroy_count: int = 0
var _generations: PackedInt32Array = PackedInt32Array()
var _retired: PackedByteArray = PackedByteArray()
var _retired_count: int = 0
var _world_tag: int = 0

## A monotonic diagnostic counter of creation, destruction, reset, store
## registration and explicit capacity growth.
var structural_version: int = 0


## [param entity_capacity] is the number of simultaneously live entities. The
## buffers are allocated at once; a rare explicit growth goes through
## [method reserve_capacity] at a loading barrier. There is no automatic growth
## in the hot loop.
func _init(entity_capacity: int) -> void:
	if entity_capacity < 1 or entity_capacity > _HANDLE_ENTITY_MASK + 1:
		push_error("EcsWorld: initial capacity %d is outside the range 1..%d; created a safe world with capacity 1"
			% [entity_capacity, _HANDLE_ENTITY_MASK + 1])
		capacity = 1
	else:
		capacity = entity_capacity
	if _next_world_tag > _HANDLE_WORLD_MASK:
		push_error("EcsWorld: in-process world tags are exhausted; generational handles are unavailable")
		_world_tag = 0
	else:
		_world_tag = _next_world_tag
		_next_world_tag += 1
	_alive.resize(capacity)
	_free_ids.resize(capacity)
	_destroy_queue.resize(capacity)
	_destroy_generation.resize(capacity)
	_destroy_flag.resize(capacity)
	_generations.resize(capacity)
	_retired.resize(capacity)
	reset()


## Registers [param store] under the identifier [param component_type_id] and
## initializes it (allocating its internal arrays for the world's current
## capacity). Every store must be registered exactly once, before the first
## entity is created — usually all together, in one place while building the
## world.
##
## The type identifier is any integer you like (usually a constant from your own
## enum). The world uses it only for [method get_store] and diagnostics; it does
## not affect speed.
func register_store(store: EcsComponentStore, component_type_id: int) -> bool:
	if _schema_locked:
		push_error("EcsWorld: the schema is locked by the first create_entity(); register stores in advance")
		return false
	if store == null:
		push_error("EcsWorld: register_store() got null")
		return false
	if _stores_by_type.has(component_type_id):
		push_error("EcsWorld: component type %d is already registered — check whether a type constant is duplicated"
			% component_type_id)
		return false
	if _stores.has(store) or store.is_initialized():
		push_error("EcsWorld: the store is already registered under another type or in another world")
		return false
	if not store.initialize(component_type_id, capacity, self):
		return false
	_stores.append(store)
	_stores_by_type[component_type_id] = store
	structural_version += 1
	return true


## Returns the registered store for a type identifier, or null.
##
## Meant for building the world, debugging and tooling. Do NOT do this in a
## system's hot loop: keep a typed reference to the store in your own context
## object and access it directly — that is both faster (no dictionary lookup) and
## statically typed.
func get_store(component_type_id: int) -> EcsComponentStore:
	return _stores_by_type.get(component_type_id)


func has_store(component_type_id: int) -> bool:
	return _stores_by_type.has(component_type_id)


## Allocates a new entity id from the free pool. Returns -1 when there are no
## free ids left (the world is completely full) — the calling code must check
## for this rather than assume creation always succeeds. See
## [EcsCapacityPolicySystem] about growing the world before this happens.
func create_entity() -> int:
	if _free_count == 0:
		return -1
	_schema_locked = true
	_free_count -= 1
	var entity: int = _free_ids[_free_count]
	_alive[entity] = 1
	_live_count += 1
	structural_version += 1
	return entity


## Allocates up to [param entity_count] entities in one pass, writing their ids
## into [param out_entities], and returns how many were actually created (less
## than requested if the world ran out of free ids).
##
## This is the spawn counterpart of [method flush_destroy_queue]: a wave spawner,
## a particle burst or a cell-division step create dozens or hundreds of entities
## per frame, and paying the call overhead once instead of N times is a clear
## win. [param out_entities] must be sized for the request in advance; it is
## filled in place.
##
## [codeblock]
## var spawned: int = world.create_entities(32, _spawn_buffer)
## positions.attach_many(_spawn_buffer, spawned)
## [/codeblock]
func create_entities(entity_count: int, out_entities: PackedInt32Array) -> int:
	if entity_count <= 0:
		return 0
	var available: int = mini(entity_count, _free_count)
	if available > out_entities.size():
		push_error("EcsWorld: the create_entities() output buffer holds %d, but %d are needed"
			% [out_entities.size(), available])
		available = out_entities.size()
	if available <= 0:
		return 0
	_schema_locked = true

	var free_ids: PackedInt32Array = _free_ids
	var alive: PackedByteArray = _alive
	var free_count: int = _free_count
	for i in available:
		free_count -= 1
		var entity: int = free_ids[free_count]
		alive[entity] = 1
		out_entities[i] = entity
	_free_count = free_count
	_live_count += available
	structural_version += 1
	return available


## Creates an entity and immediately returns a handle that is safe across frames.
## Resolve it through entity_from_handle() before indexing stores.
func create_entity_handle() -> int:
	if _world_tag == 0:
		return INVALID_HANDLE
	var entity: int = create_entity()
	return make_handle(entity) if entity >= 0 else INVALID_HANDLE


## Packs the raw entity id and the current generation into a positive 64-bit
## number. Returns INVALID_HANDLE if the entity is not alive.
func make_handle(entity: int) -> int:
	if _world_tag == 0 or not is_alive(entity):
		return INVALID_HANDLE
	return (int(_world_tag) << _HANDLE_WORLD_SHIFT) \
		| (int(_generations[entity]) << _HANDLE_GENERATION_SHIFT) \
		| entity


## Resolves a handle to the current raw id, or INVALID_ENTITY if it has gone
## stale.
func entity_from_handle(handle: int) -> int:
	if handle <= INVALID_HANDLE or _world_tag == 0:
		return INVALID_ENTITY
	var world_tag: int = int((handle >> _HANDLE_WORLD_SHIFT) & _HANDLE_WORLD_MASK)
	if world_tag != _world_tag:
		return INVALID_ENTITY
	var entity: int = int(handle & _HANDLE_ENTITY_MASK)
	if entity < 0 or entity >= capacity or _alive[entity] == 0:
		return INVALID_ENTITY
	var generation: int = int((handle >> _HANDLE_GENERATION_SHIFT) & _HANDLE_GENERATION_MASK)
	if generation == 0 or _generations[entity] != generation:
		return INVALID_ENTITY
	return entity


func is_handle_alive(handle: int) -> bool:
	return entity_from_handle(handle) != INVALID_ENTITY


## A safe entry point for destroying targets and owners kept across frames.
## Returns false for an invalid or already stale handle.
func queue_destroy_handle(handle: int) -> bool:
	var entity: int = entity_from_handle(handle)
	if entity == INVALID_ENTITY:
		return false
	return queue_destroy(entity)


func is_handle_pending_destroy(handle: int) -> bool:
	var entity: int = entity_from_handle(handle)
	return entity != INVALID_ENTITY and _destroy_flag[entity] == 1


func get_generation(entity: int) -> int:
	if entity < 0 or entity >= capacity:
		return 0
	return _generations[entity]


func get_world_tag() -> int:
	return _world_tag


func is_alive(entity: int) -> bool:
	if entity < 0 or entity >= capacity:
		return false
	return _alive[entity] == 1


## Marks [param entity] for destruction. Does NOT remove it — the real removal is
## done by [method flush_destroy_queue] at the end of the frame.
##
## Idempotent: if the entity is already in the queue (or already dead), a
## repeated call does nothing. This guards against double-queuing when several
## systems in one frame independently decide to destroy the same entity.
func queue_destroy(entity: int) -> bool:
	if entity < 0 or entity >= capacity:
		return false
	if _alive[entity] == 0 or _destroy_flag[entity] == 1:
		return false
	_destroy_flag[entity] = 1
	_destroy_queue[_destroy_count] = entity
	_destroy_generation[_destroy_count] = _generations[entity]
	_destroy_count += 1
	return true


## Marks [param entity_count] entities from [param entities] for destruction and
## returns how many of them entered the queue for the first time.
func queue_destroy_many(entities: PackedInt32Array, entity_count: int) -> int:
	if entity_count <= 0:
		return 0
	if entity_count > entities.size():
		entity_count = entities.size()
	var queued: int = 0
	var limit: int = capacity
	var alive: PackedByteArray = _alive
	var flags: PackedByteArray = _destroy_flag
	var queue: PackedInt32Array = _destroy_queue
	var stamps: PackedInt32Array = _destroy_generation
	var generations: PackedInt32Array = _generations
	var write: int = _destroy_count
	for i in entity_count:
		var entity: int = entities[i]
		if entity < 0 or entity >= limit:
			continue
		if alive[entity] == 0 or flags[entity] == 1:
			continue
		flags[entity] = 1
		queue[write] = entity
		stamps[write] = generations[entity]
		write += 1
		queued += 1
	_destroy_count = write
	return queued


func is_pending_destroy(entity: int) -> bool:
	return entity >= 0 and entity < capacity and _destroy_flag[entity] == 1


## Performs the REAL destruction of every entity accumulated in the queue: each
## one is detached from every registered store, marked dead and returned to the
## free pool. Returns the number of destroyed entities.
##
## This is a structural sync point — call it only between phases, when no system
## is holding a dense slot. A repeated empty flush is safe.
##
## [b]The loop iterates by store, not by entity.[/b] Instead of asking every
## store about every entity (a property read plus a method call per pair), each
## store is handed the whole list of victims once and runs its own dense loop
## (see [method EcsComponentStore.detach_many]). With a dozen stores, most
## entities do not have most components, so the "no such component" path decides
## everything — and that path drops from a method call to a single local array
## read.
func flush_destroy_queue() -> int:
	var queued: int = _destroy_count
	_destroy_count = 0
	if queued == 0:
		return 0

	# Resolve the queue keys and compact the survivors into the front of the same
	# array, which then serves as the list of victims handed to the stores.
	var queue: PackedInt32Array = _destroy_queue
	var stamps: PackedInt32Array = _destroy_generation
	var flags: PackedByteArray = _destroy_flag
	var generations: PackedInt32Array = _generations
	var alive: PackedByteArray = _alive
	var reaped: int = 0
	for i in queued:
		var entity: int = queue[i]
		if entity < 0 or entity >= capacity or alive[entity] == 0 \
				or stamps[i] == 0 or generations[entity] != stamps[i]:
			# Defensive branch: within a single flush loop a marked entity always
			# resolves, since generations only change here. The flag is cleared
			# anyway so a stale one does not survive the loop.
			if entity >= 0 and entity < capacity:
				flags[entity] = 0
			continue
		queue[reaped] = entity
		reaped += 1
	if reaped == 0:
		return 0

	# The victims' flags stay set for the whole duration of this loop so that
	# each store can pick the cheaper of two traversals.
	#
	# Iterating its own dense array (detach_flagged) costs O(count), but it knows
	# in advance which elements are doomed, so it relocates the minimum — zero
	# when the store is wiped entirely. Iterating the list of victims
	# (detach_many) costs O(reaped) but relocates once per removal. A store wins
	# while it is not much larger than the list of victims; past roughly twice
	# the size the extra iterations outweigh the saved relocations, because at
	# that size only a small fraction of the store is removed.
	var flagged_limit: int = reaped * 2
	for store in _stores:
		var held: int = store.count
		if held == 0:
			continue
		if held <= flagged_limit:
			store.detach_flagged(flags)
		else:
			store.detach_many(queue, reaped)

	var free_ids: PackedInt32Array = _free_ids
	var retired: PackedByteArray = _retired
	var free_count: int = _free_count
	var retired_count: int = _retired_count
	for i in reaped:
		var entity: int = queue[i]
		alive[entity] = 0
		flags[entity] = 0
		var next_generation: int = _next_generation(generations[entity])
		if next_generation == 0:
			retired[entity] = 1
			retired_count += 1
		else:
			generations[entity] = next_generation
			free_ids[free_count] = entity
			free_count += 1
	_free_count = free_count
	_retired_count = retired_count
	_live_count -= reaped
	structural_version += 1
	return reaped


func get_live_count() -> int:
	return _live_count


func get_free_count() -> int:
	return _free_count


func get_retired_count() -> int:
	return _retired_count


func get_pending_destroy_count() -> int:
	return _destroy_count


## The fraction of the world occupied by live entities, in [0, 1].
## [EcsCapacityPolicySystem] runs on it, and it is handy to show on a debug HUD.
func get_load_factor() -> float:
	return float(_live_count) / float(capacity)


## The number of registered component stores.
func get_store_count() -> int:
	return _stores.size()


func get_store_at(index: int) -> EcsComponentStore:
	return _stores[index]


func is_schema_locked() -> bool:
	return _schema_locked


## Clears the structural change log of every registered store that has it
## enabled. Call it once per frame, after the systems that consume the logs have
## run.
func clear_change_logs() -> void:
	for store in _stores:
		if store.track_changes:
			store.clear_change_log()


## Explicitly grows all the world's and stores' buffers. Existing raw ids,
## handles and dense slots stay valid. The operation allocates; call it only at a
## safe loading boundary, never during a system iteration.
##
## Returns false, touching nothing, if at least one registered store cannot grow:
## a store supports growth exactly when it defines `_grow_dense()`.
## [EcsPackedStore] and [EcsTagStore] always can.
func reserve_capacity(entity_capacity: int) -> bool:
	if entity_capacity <= capacity:
		return false
	if entity_capacity > _HANDLE_ENTITY_MASK + 1:
		push_error("EcsWorld: capacity is outside the generational-handle range")
		return false
	for store in _stores:
		if store.get_capacity() != capacity \
				or not store._can_grow_capacity_from_world(entity_capacity, self):
			push_error("EcsWorld: the store of type %d cannot safely grow to %d — it needs a _grow_dense() hook"
				% [store.type_id, entity_capacity])
			return false
	var previous_capacity: int = capacity
	_alive.resize(entity_capacity)
	_free_ids.resize(entity_capacity)
	_destroy_queue.resize(entity_capacity)
	_destroy_generation.resize(entity_capacity)
	_destroy_flag.resize(entity_capacity)
	_generations.resize(entity_capacity)
	_retired.resize(entity_capacity)
	for entity in range(previous_capacity, entity_capacity):
		_alive[entity] = 0
		_destroy_flag[entity] = 0
		_generations[entity] = 1
		_retired[entity] = 0
		_free_ids[_free_count] = entity
		_free_count += 1
	for store in _stores:
		store._commit_capacity_growth_from_world(entity_capacity, self)
	capacity = entity_capacity
	structural_version += 1
	return true


## Fully resets the world — every entity "dies", every store is cleared — with no
## allocation at all: the arrays are simply refilled. Suitable for restarting a
## level without recreating the world and losing the pre-allocated memory.
##
## Store registrations are kept, so [method register_store] must not (and need
## not) be called again.
func reset() -> void:
	_destroy_count = 0
	_free_count = 0
	_retired_count = 0
	# The free list is filled in descending order, so ids are handed out in
	# ascending order (a LIFO stack: the last one written is the first one out).
	# A slot with an exhausted generation stays retired forever, so an old handle
	# cannot come back to life.
	for i in capacity:
		var entity: int = capacity - 1 - i
		if _retired[entity] == 1:
			_retired_count += 1
			continue
		if _generations[entity] == 0:
			_generations[entity] = 1
		elif _alive[entity] == 1:
			var next_generation: int = _next_generation(_generations[entity])
			if next_generation == 0:
				_alive[entity] = 0
				_destroy_flag[entity] = 0
				_retired[entity] = 1
				_retired_count += 1
				continue
			_generations[entity] = next_generation
		_alive[entity] = 0
		_destroy_flag[entity] = 0
		_free_ids[_free_count] = entity
		_free_count += 1
	_live_count = 0
	for store in _stores:
		store.clear()
	structural_version += 1


## An expensive check of the allocator, the destroy queue and every sparse set,
## for the development stage. Call it from tests, an editor command or a rare
## debug system; never from a production frame.
func validate_integrity(report_errors: bool = true) -> bool:
	var valid := true
	if _alive.size() != capacity or _free_ids.size() != capacity \
			or _destroy_queue.size() != capacity or _destroy_generation.size() != capacity \
			or _destroy_flag.size() != capacity \
			or _generations.size() != capacity or _retired.size() != capacity:
		if report_errors:
			push_error("EcsWorld: the lifecycle buffer sizes do not match the capacity")
		return false
	if _live_count < 0 or _free_count < 0 or _retired_count < 0 \
			or _live_count + _free_count + _retired_count != capacity:
		valid = false
		if report_errors:
			push_error("EcsWorld: the live/free/retired counters do not add up to the capacity")
	if _destroy_count < 0 or _destroy_count > capacity:
		valid = false
		if report_errors:
			push_error("EcsWorld: destroy_count is outside the capacity")

	var free_seen := PackedByteArray()
	free_seen.resize(capacity)
	for index in clampi(_free_count, 0, capacity):
		var entity: int = _free_ids[index]
		if entity < 0 or entity >= capacity:
			valid = false
			if report_errors:
				push_error("EcsWorld: the free list contains an invalid entity %d" % entity)
			continue
		if free_seen[entity] == 1 or _alive[entity] == 1:
			valid = false
			if report_errors:
				push_error("EcsWorld: a duplicate or live entity %d is in the free list" % entity)
		free_seen[entity] = 1

	var destroy_seen := PackedByteArray()
	destroy_seen.resize(capacity)
	for index in clampi(_destroy_count, 0, capacity):
		var entity: int = _destroy_queue[index]
		if entity < 0 or entity >= capacity:
			valid = false
			if report_errors:
				push_error("EcsWorld: the destroy queue contains an invalid entity %d" % entity)
			continue
		if destroy_seen[entity] == 1 or _alive[entity] == 0 or _destroy_flag[entity] == 0:
			valid = false
			if report_errors:
				push_error("EcsWorld: an inconsistent entity %d is in the destroy queue" % entity)
		destroy_seen[entity] = 1

	var counted_alive: int = 0
	for entity in capacity:
		if _generations[entity] <= 0:
			valid = false
			if report_errors:
				push_error("EcsWorld: entity %d has a zero generation" % entity)
		if _alive[entity] == 1:
			if _retired[entity] == 1:
				valid = false
				if report_errors:
					push_error("EcsWorld: retired entity %d is marked alive" % entity)
			counted_alive += 1
		elif free_seen[entity] == 0 and _retired[entity] == 0:
			valid = false
			if report_errors:
				push_error("EcsWorld: dead entity %d is missing from the free list" % entity)
		if _destroy_flag[entity] != destroy_seen[entity]:
			valid = false
			if report_errors:
				push_error("EcsWorld: the destroy flag does not match the queue for entity %d" % entity)
		if _retired[entity] == 1 and free_seen[entity] == 1:
			valid = false
			if report_errors:
				push_error("EcsWorld: retired entity %d is present in the free list" % entity)
	if counted_alive != _live_count:
		valid = false
		if report_errors:
			push_error("EcsWorld: the alive flags do not match live_count")

	for store in _stores:
		if store.get_capacity() != capacity or not store.validate_integrity(_alive, report_errors):
			valid = false
	return valid


func _next_generation(current: int) -> int:
	var next: int = current + 1
	return 0 if next <= 0 or next > _HANDLE_GENERATION_MASK else next
