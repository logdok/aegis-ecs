class_name EcsTagStore
extends EcsComponentStore

## A data-less marker component.
##
## Sometimes a system does not need to know anything about an entity except the
## fact that it belongs to some category: "this is an enemy", "this is a
## projectile", "this can be picked up". A full store with payload arrays is
## redundant here: membership is already fully described by the sparse set having
## an entry for that entity.
##
## So EcsTagStore is an [EcsComponentStore] WITH NO payload: the base sparse set
## already provides everything needed — [method EcsComponentStore.attach],
## [method EcsComponentStore.detach], [method EcsComponentStore.has] and, most
## valuably, the dense array [member EcsComponentStore.dense_entities] for
## walking "every entity in category X" at full speed.
##
## The virtual hooks are overridden with explicit no-ops rather than silently
## inherited — so that "this store deliberately carries no data" is visible right
## here.

## No payload arrays — nothing to allocate.
func _reserve_dense(_dense_capacity: int) -> void:
	pass


## Declared so that EcsComponentStore auto-detects growth support: a tag always
## survives world.reserve_capacity(), since it has no data of its own to
## relocate.
func _grow_dense(_previous_capacity: int, _dense_capacity: int) -> void:
	pass


## No payload arrays — nothing to relocate on swap-remove.
func _relocate_dense(_from_slot: int, _to_slot: int) -> void:
	pass


## A specialized batched removal. A tag has no payload, so there is no relocation
## here at all — neither a virtual call per move, as in the ordinary path, nor a
## recorded move, as in the batched one.
func detach_many(entities: PackedInt32Array, entity_count: int) -> int:
	if entity_count <= 0 or count == 0:
		return 0
	if entity_count > entities.size():
		push_error("EcsTagStore(type %d): detach_many() got a count of %d for an array of size %d"
			% [type_id, entity_count, entities.size()])
		entity_count = entities.size()

	var sparse: PackedInt32Array = sparse_index
	var dense: PackedInt32Array = dense_entities
	var limit: int = get_capacity()
	var live: int = count
	var removed: int = 0
	var log_changes: bool = track_changes
	if log_changes:
		_reserve_removed(removed_count + entity_count)
	var log: PackedInt32Array = removed_entities
	var logged: int = removed_count

	for i in entity_count:
		var entity: int = entities[i]
		if entity < 0 or entity >= limit:
			continue
		var slot: int = sparse[entity]
		if slot == -1:
			continue
		live -= 1
		if slot != live:
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


## A specialized removal by flags — for the same reason as [method detach_many]:
## there is nothing to relocate, so the per-removal call disappears too.
func detach_flagged(flags: PackedByteArray) -> int:
	if count == 0:
		return 0
	var sparse: PackedInt32Array = sparse_index
	var dense: PackedInt32Array = dense_entities
	var live: int = count
	var removed: int = 0
	var log_changes: bool = track_changes
	if log_changes:
		_reserve_removed(removed_count + live)
	var log: PackedInt32Array = removed_entities
	var logged: int = removed_count

	var slot: int = 0
	while slot < live:
		while live > slot:
			var tail_entity: int = dense[live - 1]
			if flags[tail_entity] == 0:
				break
			live -= 1
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
		live -= 1
		var moved: int = dense[live]
		dense[slot] = moved
		sparse[moved] = slot
		sparse[entity] = -1
		removed += 1
		if log_changes:
			log[logged] = entity
			logged += 1
		slot += 1

	count = live
	removed_count = logged
	if removed > 0:
		structural_version += 1
	return removed
