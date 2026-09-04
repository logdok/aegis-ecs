class_name EcsComponentStore
extends RefCounted

## An abstract component store based on a sparse set.
##
## This class defines HOW component data is laid out. Its job is, for an
## arbitrary set of live entities (and entities, recall, are just integers — see
## [EcsWorld]), to store their data DENSELY, with no holes, so a system can walk
## every entity with this component in one `for i in count` loop rather than
## scanning every possible id asking "does it have the component?".
##
## [b]Memory layout[/b] — two parallel arrays working in both directions:
## [codeblock]
## sparse_index[entity_id] -> dense slot, or -1 if there is no component
## dense_entities[slot]    -> which entity this dense slot belongs to
## [/codeblock]
##
## The component DATA itself lives in the subclass, in parallel `Packed*Array`s
## addressed by THE SAME dense slot. If entity 42 occupies slot 5, look up its
## position at index 5 of the subclass's position array, not at 42.
##
## [b]What the subclass must provide[/b]: [method _reserve_dense] (allocate the
## payload arrays) and [method _relocate_dense] (move data between dense slots on
## swap-remove). Forgetting the second is a classic mistake: removal starts
## silently corrupting data, with no message in the console.
## [EcsPackedStore] implements both generically and is the recommended base for
## ordinary data components.
##
## [b]Optional hooks are detected automatically.[/b] They are deliberately NOT
## declared here, so that [method Object.has_method] can tell whether the
## subclass actually defined them. Define a hook — it is used; do not — it costs
## nothing at all. There is no flag here that you could forget:
## [codeblock]
## _grow_dense(previous_capacity, new_capacity)   # enables world.reserve_capacity()
## _relocate_dense_batch(from_slots, to_slots, n) # batched relocation with arrays lifted out
## _release_dense(slot)                           # free your own Resource/RID/Callable
## _clear_relocated_dense(slot)                   # clear the duplicate in the source slot
## _clear_dense(active_count)                     # bulk cleanup on clear()/reset()
## [/codeblock]
##
## [b]WHY THE FIELDS ARE PUBLIC[/b]: [member sparse_index], [member dense_entities]
## and [member count] are deliberately not hidden behind getters. Systems read
## them DIRECTLY inside hot loops, and a method call in GDScript costs several
## times more than an array element read (measured: ~90 ns vs ~20 ns). From
## outside the class, treat them as READ-ONLY: only the class itself and its
## subclasses may write.
##
## [b]About bounds checks[/b]: [method has], [method index_of] and
## [method entity_at] deliberately do NOT check their argument — they are
## hot-loop primitives. Structural entry points ([method attach], [method detach]
## and their batched forms) do check bounds, because they run far less often.

## The growth step of the optional change-log buffers.
const _CHANGE_LOG_MIN_CAPACITY: int = 64

var type_id: int = -1

## An optional human-readable name for tooling. Leave it empty and
## [method get_debug_name] derives it from the script's class name: a store
## declared as `class_name PositionStore` already reports as "PositionStore",
## with no bookkeeping. Set it explicitly only to override that behaviour.
var debug_name: String = ""

var sparse_index: PackedInt32Array = PackedInt32Array()
var dense_entities: PackedInt32Array = PackedInt32Array()
var count: int = 0

## Grows on every change of membership or dense-slot layout. A payload write does
## not affect it. [EcsQuery] uses this value to skip rebuilding an unchanged
## component intersection.
var structural_version: int = 0

## An opt-in log of structural changes. While it is enabled, every entity that
## gains the component is appended to [member added_entities] and every one that
## loses it to [member removed_entities], until [method clear_change_log] is
## called. This is the supported way to react to "appeared" and "died" without
## polling.
##
## Disabled, it costs one check per structural operation, that is effectively
## nothing. Enabling it allocates two log buffers that grow by doubling until
## they reach the size of typical per-frame churn.
var track_changes: bool = false:
	set(value):
		track_changes = value
		if value and added_entities.size() == 0:
			added_entities.resize(_CHANGE_LOG_MIN_CAPACITY)
			removed_entities.resize(_CHANGE_LOG_MIN_CAPACITY)

## The valid prefix is [0, added_count). Cleared by [method clear_change_log].
var added_entities: PackedInt32Array = PackedInt32Array()
var added_count: int = 0

## The valid prefix is [0, removed_count). Cleared by [method clear_change_log].
var removed_entities: PackedInt32Array = PackedInt32Array()
var removed_count: int = 0

## Set when [method clear] or [method EcsWorld.reset] wiped the store while the
## log was enabled. Individual removals are NOT recorded in that case: a full
## reset would otherwise run the entire population through the log.
var change_log_overflowed: bool = false

var _capacity: int = 0
var _initialized: bool = false
## Identity only: a strong reference to the owner would form a RefCounted cycle
## (world -> stores -> world) and both objects would leak.
var _owner_world_id: int = 0

# Optional hooks, resolved once in initialize().
var _supports_growth: bool = false
var _has_batch_relocate: bool = false
var _tracks_ownership: bool = false
var _has_clear_relocated: bool = false
var _has_clear_dense: bool = false

# Scratch buffers for batched relocation, grown as needed.
var _move_from: PackedInt32Array = PackedInt32Array()
var _move_to: PackedInt32Array = PackedInt32Array()


## Called from [method EcsWorld.register_store]. You do not need to call it
## manually.
func initialize(component_type_id: int, entity_capacity: int, owner_world) -> bool:
	if _initialized:
		push_error("EcsComponentStore: initialize() was called twice")
		return false
	type_id = component_type_id
	_owner_world_id = owner_world.get_instance_id()
	_capacity = entity_capacity

	# Resolve the optional hooks once. has_method() is exact here precisely
	# because this class declares none of them.
	_supports_growth = has_method(&"_grow_dense")
	_has_batch_relocate = has_method(&"_relocate_dense_batch")
	_tracks_ownership = has_method(&"_release_dense")
	_has_clear_relocated = has_method(&"_clear_relocated_dense")
	_has_clear_dense = has_method(&"_clear_dense")
	if _has_clear_relocated and not _tracks_ownership:
		push_error("EcsComponentStore(type %d): _clear_relocated_dense() without _release_dense() — "
			% component_type_id + "the source slot will be cleared, but the removed data will never be freed")

	sparse_index.resize(entity_capacity)
	sparse_index.fill(-1)
	dense_entities.resize(entity_capacity)
	count = 0
	_reserve_dense(entity_capacity)
	structural_version += 1
	_initialized = true
	return true


## True when the subclass defined `_grow_dense()` — that is exactly what makes
## the store safe for [method EcsWorld.reserve_capacity].
func supports_capacity_growth() -> bool:
	return _supports_growth


## The internal half of EcsWorld.reserve_capacity(). Growing an individual store
## directly is deliberately impossible: every store's capacity must match its
## owner world's.
func _can_grow_capacity_from_world(dense_capacity: int, owner_world) -> bool:
	return owner_world != null \
		and owner_world.get_instance_id() == _owner_world_id \
		and dense_capacity > _capacity \
		and _supports_growth


func _commit_capacity_growth_from_world(dense_capacity: int, owner_world) -> void:
	# EcsWorld runs one full pre-check before touching any buffer. This commit
	# deliberately does not re-check feasibility, so a hook with internal state
	# cannot create a partially applied transaction.
	assert(owner_world != null and owner_world.get_instance_id() == _owner_world_id)
	assert(dense_capacity > _capacity)
	var previous_capacity: int = _capacity
	sparse_index.resize(dense_capacity)
	for entity in range(previous_capacity, dense_capacity):
		sparse_index[entity] = -1
	dense_entities.resize(dense_capacity)
	_capacity = dense_capacity
	call(&"_grow_dense", previous_capacity, dense_capacity)
	structural_version += 1


## [b]Mandatory override.[/b] Allocate (resize) the subclass's payload arrays for
## [param dense_capacity] elements. The base class cannot do it for you because
## it does not know what data you store.
func _reserve_dense(_dense_capacity: int) -> void:
	pass


## [b]Mandatory override.[/b] Copy the component DATA from dense slot
## [param from_slot] to [param to_slot]. The entity ids themselves are moved by
## the base class. Called on swap-remove, for example:
## `position[to_slot] = position[from_slot]`.
func _relocate_dense(_from_slot: int, _to_slot: int) -> void:
	pass


## Attaches the component to [param entity] and returns its dense slot.
## Idempotent: if the component is already attached, the existing slot is
## returned. Returns -1 when the capacity is exhausted or the id is out of range.
##
## A new slot is always appended to the END of the dense array — that is exactly
## what keeps the array contiguous from 0 to count-1.
func attach(entity: int) -> int:
	if entity < 0 or entity >= _capacity:
		push_error("EcsComponentStore(type %d): entity %d is outside the capacity" % [type_id, entity])
		return -1
	var existing: int = sparse_index[entity]
	if existing != -1:
		return existing
	if count >= _capacity:
		push_error("EcsComponentStore(type %d): dense capacity is exhausted" % type_id)
		return -1
	var slot: int = count
	sparse_index[entity] = slot
	dense_entities[slot] = entity
	count = slot + 1
	structural_version += 1
	if track_changes:
		_push_added(entity)
	return slot


## Attaches the component to [param entity_count] entities from [param entities]
## in one pass and returns how many were attached for the first time.
##
## This is the spawn counterpart of [method detach_many]: the store overhead is
## paid once rather than per entity. Entities that already have the component are
## skipped.
##
## [b]Slot layout[/b]: the new components occupy the dense slots
## `[old_count, old_count + attached)` in the order the entities appear in
## [param entities]. Take [member count] BEFORE the call to get `old_count`, and
## write the data straight into those slots:
## [codeblock]
## var first: int = store.count
## store.attach_many(spawned_ids, spawned)
## for i in spawned:
##     store.health[first + i] = 100.0
## [/codeblock]
func attach_many(entities: PackedInt32Array, entity_count: int) -> int:
	if entity_count <= 0:
		return 0
	if entity_count > entities.size():
		push_error("EcsComponentStore(type %d): attach_many() got a count of %d for an array of size %d"
			% [type_id, entity_count, entities.size()])
		entity_count = entities.size()

	var sparse: PackedInt32Array = sparse_index
	var dense: PackedInt32Array = dense_entities
	var live: int = count
	var limit: int = _capacity
	var attached: int = 0
	var log_changes: bool = track_changes
	if log_changes:
		_reserve_added(added_count + entity_count)
	var log: PackedInt32Array = added_entities
	var logged: int = added_count

	for i in entity_count:
		var entity: int = entities[i]
		if entity < 0 or entity >= limit:
			push_error("EcsComponentStore(type %d): entity %d is outside the capacity" % [type_id, entity])
			continue
		if sparse[entity] != -1:
			continue
		if live >= limit:
			push_error("EcsComponentStore(type %d): dense capacity is exhausted" % type_id)
			break
		sparse[entity] = live
		dense[live] = entity
		live += 1
		attached += 1
		if log_changes:
			log[logged] = entity
			logged += 1

	count = live
	added_count = logged
	if attached > 0:
		structural_version += 1
	return attached


## Detaches the component from [param entity]. Safe to call even if the entity
## has no such component — then it is a no-op.
##
## [b]SWAP-REMOVE[/b] is the whole reason a sparse set exists. To remove an
## element from the MIDDLE of the dense array without leaving a hole and without
## shifting the tail (which would be O(n) per removal), the LAST element is moved
## into the freed spot:
## [codeblock]
## 1. slot = the dense slot being freed (it belonged to `entity`)
## 2. last = the index of the last occupied slot (count - 1)
## 3. if slot != last: copy the data from last to slot (_relocate_dense),
##    then redirect BOTH mappings of the moved entity to the new slot
## 4. mark `entity` as having no component and decrement count
## [/codeblock]
## The cost is O(1) regardless of the array size. The price: the order in the
## dense array is NOT preserved, so systems must not depend on the iteration
## order.
func detach(entity: int) -> void:
	if entity < 0 or entity >= _capacity:
		return
	var slot: int = sparse_index[entity]
	if slot == -1:
		return
	var last: int = count - 1
	if _tracks_ownership:
		call(&"_release_dense", slot)
	if slot != last:
		_relocate_dense(last, slot)
		if _has_clear_relocated:
			call(&"_clear_relocated_dense", last)
		var moved: int = dense_entities[last]
		dense_entities[slot] = moved
		sparse_index[moved] = slot
	sparse_index[entity] = -1
	count = last
	structural_version += 1
	if track_changes:
		_push_removed(entity)


## Detaches the component from [param entity_count] entities from
## [param entities] in one pass and returns how many components were actually
## removed.
##
## [b]This is the batched destruction path[/b], and the reason
## [method EcsWorld.flush_destroy_queue] iterates by store rather than by entity.
## The loop here can keep the sparse/dense arrays in local variables, so an
## entity that does NOT have this component costs one local array read instead of
## an object field read plus a method call. With a dozen stores, most entities do
## not have most components, so it is this skip path that determines the total
## cost.
##
## The semantics are identical to calling [method detach] for each entity in
## order.
func detach_many(entities: PackedInt32Array, entity_count: int) -> int:
	if entity_count <= 0 or count == 0:
		return 0
	if entity_count > entities.size():
		push_error("EcsComponentStore(type %d): detach_many() got a count of %d for an array of size %d"
			% [type_id, entity_count, entities.size()])
		entity_count = entities.size()

	var sparse: PackedInt32Array = sparse_index
	var dense: PackedInt32Array = dense_entities
	# Lifted out of the loops below: reading a `self` property costs several times
	# more than an indexed read of a local variable, and this runs once per
	# (entity, store) pair.
	var limit: int = _capacity
	var live: int = count
	var removed: int = 0
	var log_changes: bool = track_changes
	if log_changes:
		_reserve_removed(removed_count + entity_count)
	var log: PackedInt32Array = removed_entities
	var logged: int = removed_count

	if _tracks_ownership:
		# Data the store owns must be released BEFORE anything overwrites it, so
		# here the relocation must stay interleaved with the mapping updates.
		var clear_relocated: bool = _has_clear_relocated
		for i in entity_count:
			var entity: int = entities[i]
			if entity < 0 or entity >= limit:
				continue
			var slot: int = sparse[entity]
			if slot == -1:
				continue
			live -= 1
			call(&"_release_dense", slot)
			if slot != live:
				_relocate_dense(live, slot)
				if clear_relocated:
					call(&"_clear_relocated_dense", live)
				var moved: int = dense[live]
				dense[slot] = moved
				sparse[moved] = slot
			sparse[entity] = -1
			removed += 1
			if log_changes:
				log[logged] = entity
				logged += 1
	elif _has_batch_relocate:
		# No ownership hooks means nothing reads the payload as the loop
		# proceeds, so all the moves can be recorded and applied afterwards in
		# one pass. Applying them in recorded order is exactly equivalent to
		# interleaving, but lets the subclass lift its array lookup out of the
		# per-move loop.
		_reserve_move_scratch(entity_count)
		var move_from: PackedInt32Array = _move_from
		var move_to: PackedInt32Array = _move_to
		var moves: int = 0
		for i in entity_count:
			var entity: int = entities[i]
			if entity < 0 or entity >= limit:
				continue
			var slot: int = sparse[entity]
			if slot == -1:
				continue
			live -= 1
			if slot != live:
				move_from[moves] = live
				move_to[moves] = slot
				moves += 1
				var moved: int = dense[live]
				dense[slot] = moved
				sparse[moved] = slot
			sparse[entity] = -1
			removed += 1
			if log_changes:
				log[logged] = entity
				logged += 1
		if moves > 0:
			call(&"_relocate_dense_batch", move_from, move_to, moves)
	else:
		for i in entity_count:
			var entity: int = entities[i]
			if entity < 0 or entity >= limit:
				continue
			var slot: int = sparse[entity]
			if slot == -1:
				continue
			live -= 1
			if slot != live:
				_relocate_dense(live, slot)
				var moved: int = dense[live]
				dense[slot] = moved
				sparse[moved] = slot
			sparse[entity] = -1
			removed += 1
			if log_changes:
				log[logged] = entity
				logged += 1

	count = live
	removed_count = logged
	if removed > 0:
		structural_version += 1
	return removed


## Detaches every entity whose byte in [param flags] is non-zero and returns how
## many components were removed.
##
## This is the second half of the batched destruction path. [method detach_many]
## costs O(victims) per store, which is wasteful for a store much smaller than
## the list of victims: a one-component "turret" store would still walk ten
## thousand victims. This form costs O(count), so
## [method EcsWorld.flush_destroy_queue] picks whichever list is shorter. With a
## schema of many specialized small stores, this is the difference between
## O(victims x stores) and O(sum of store sizes).
##
## [param flags] is indexed by entity id and must be no shorter than the store's
## capacity. The removal order is undefined — do not rely on it, including in the
## change log.
##
## [b]It also performs the theoretical minimum of relocations.[/b] Knowing in
## advance which entities are doomed, the method never moves a doomed element
## into a just-freed slot only to remove it again a moment later: the marked
## elements are first cut from the tail, and a real move happens only when a hole
## has to be filled by a survivor. So wiping the whole population — a level
## restart, a routed wave — performs ZERO moves, whereas the victim-list path
## does one per removal.
func detach_flagged(flags: PackedByteArray) -> int:
	if count == 0:
		return 0
	var sparse: PackedInt32Array = sparse_index
	var dense: PackedInt32Array = dense_entities
	var live: int = count
	var removed: int = 0
	var owns: bool = _tracks_ownership
	var clear_relocated: bool = _has_clear_relocated
	var log_changes: bool = track_changes
	if log_changes:
		_reserve_removed(removed_count + live)
	var log: PackedInt32Array = removed_entities
	var logged: int = removed_count

	var slot: int = 0
	while slot < live:
		# First cut the marked elements from the tail. Nothing needs to move into
		# their place, so each costs a single write to sparse.
		while live > slot:
			var tail_entity: int = dense[live - 1]
			if flags[tail_entity] == 0:
				break
			live -= 1
			if owns:
				call(&"_release_dense", live)
			sparse[tail_entity] = -1
			removed += 1
			if log_changes:
				log[logged] = tail_entity
				logged += 1
		if slot >= live:
			break

		var entity: int = dense[slot]
		if flags[entity] == 0:
			slot += 1
			continue

		# This slot is doomed and the tail element is a survivor, so this is a
		# move that is genuinely necessary.
		live -= 1
		if owns:
			call(&"_release_dense", slot)
		_relocate_dense(live, slot)
		if clear_relocated:
			call(&"_clear_relocated_dense", live)
		var moved: int = dense[live]
		dense[slot] = moved
		sparse[moved] = slot
		sparse[entity] = -1
		removed += 1
		if log_changes:
			log[logged] = entity
			logged += 1
		# The survivor just written here is certainly not flagged, so the slot
		# does not need re-checking.
		slot += 1

	count = live
	removed_count = logged
	if removed > 0:
		structural_version += 1
	return removed


func has(entity: int) -> bool:
	return sparse_index[entity] != -1


## The entity's dense slot, or -1 if it has no such component.
func index_of(entity: int) -> int:
	return sparse_index[entity]


## The entity that owns dense slot [param dense_slot].
func entity_at(dense_slot: int) -> int:
	return dense_entities[dense_slot]


## Empties the store with no allocation at all: it resets [member sparse_index]
## and [member count]. The data physically stays in place but becomes
## unreachable — at count == 0 no system sees it, and the next [method attach]
## overwrites it.
##
## Individual removals are not written to the change log; instead
## [member change_log_overflowed] is raised, because running the whole
## population through the log on a level restart is never what the calling code
## wants.
func clear() -> void:
	var had_components: bool = count > 0
	if had_components and _has_clear_dense:
		call(&"_clear_dense", count)
	sparse_index.fill(-1)
	count = 0
	if had_components:
		structural_version += 1
		if track_changes:
			change_log_overflowed = true
			added_count = 0
			removed_count = 0


## Resets everything accumulated since the last call. Call it once per frame,
## after the systems that consume the log have run.
func clear_change_log() -> void:
	added_count = 0
	removed_count = 0
	change_log_overflowed = false


## A name for diagnostics and the debug interface. Cold path only.
##
## Falls back to the script's global class name, then to "type N", so tooling
## never has to show a bare number and stores never have to be annotated by hand.
func get_debug_name() -> String:
	if not debug_name.is_empty():
		return debug_name
	var script: Script = get_script()
	if script != null:
		var global_name: String = String(script.get_global_name())
		if not global_name.is_empty():
			return global_name
	return "type %d" % type_id


func get_capacity() -> int:
	return _capacity


func is_initialized() -> bool:
	return _initialized


## An expensive invariant check for the development stage. Deliberately called on
## demand and allocates nothing except the error strings in push_error().
func validate_integrity(alive: PackedByteArray = PackedByteArray(), report_errors: bool = true) -> bool:
	var valid := true
	if count < 0 or count > _capacity:
		valid = false
		if report_errors:
			push_error("EcsComponentStore(type %d): count %d is outside the capacity %d" % [type_id, count, _capacity])
	if sparse_index.size() != _capacity or dense_entities.size() != _capacity:
		valid = false
		if report_errors:
			push_error("EcsComponentStore(type %d): the sparse/dense size does not match the capacity" % type_id)
		return false
	if not alive.is_empty() and alive.size() != _capacity:
		valid = false
		if report_errors:
			push_error("EcsComponentStore(type %d): the alive size does not match the capacity" % type_id)
		return false

	for dense_slot in clampi(count, 0, _capacity):
		var entity: int = dense_entities[dense_slot]
		if entity < 0 or entity >= _capacity:
			valid = false
			if report_errors:
				push_error("EcsComponentStore(type %d): dense slot %d contains an invalid entity %d" % [type_id, dense_slot, entity])
			continue
		if sparse_index[entity] != dense_slot:
			valid = false
			if report_errors:
				push_error("EcsComponentStore(type %d): the dense->sparse mapping is broken for entity %d" % [type_id, entity])
		if not alive.is_empty() and alive[entity] == 0:
			valid = false
			if report_errors:
				push_error("EcsComponentStore(type %d): a component is attached to dead entity %d" % [type_id, entity])

	for entity in _capacity:
		var dense_slot: int = sparse_index[entity]
		if dense_slot == -1:
			continue
		if dense_slot < 0 or dense_slot >= count or dense_slot >= _capacity:
			valid = false
			if report_errors:
				push_error("EcsComponentStore(type %d): sparse slot %d is outside count for entity %d" % [type_id, dense_slot, entity])
			continue
		if dense_entities[dense_slot] != entity:
			valid = false
			if report_errors:
				push_error("EcsComponentStore(type %d): the sparse->dense mapping is broken for entity %d" % [type_id, entity])
	return valid


func _push_added(entity: int) -> void:
	_reserve_added(added_count + 1)
	added_entities[added_count] = entity
	added_count += 1


func _push_removed(entity: int) -> void:
	_reserve_removed(removed_count + 1)
	removed_entities[removed_count] = entity
	removed_count += 1


func _reserve_added(required: int) -> void:
	if added_entities.size() >= required:
		return
	var size: int = maxi(added_entities.size(), _CHANGE_LOG_MIN_CAPACITY)
	while size < required:
		size *= 2
	added_entities.resize(size)


func _reserve_removed(required: int) -> void:
	if removed_entities.size() >= required:
		return
	var size: int = maxi(removed_entities.size(), _CHANGE_LOG_MIN_CAPACITY)
	while size < required:
		size *= 2
	removed_entities.resize(size)


func _reserve_move_scratch(required: int) -> void:
	if _move_from.size() >= required:
		return
	_move_from.resize(required)
	_move_to.resize(required)
