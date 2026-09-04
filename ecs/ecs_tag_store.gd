class_name EcsTagStore
extends EcsComponentStore

## Компонент-метка без данных.
##
## Иногда системе не нужно знать о сущности ничего, кроме самого факта, что она
## принадлежит к некоторой категории: «это враг», «это снаряд», «это можно
## подобрать». Полноценное хранилище с payload-массивами здесь избыточно:
## принадлежность уже полностью описана тем, что sparse set содержит запись для
## этой сущности.
##
## Поэтому EcsTagStore — это [EcsComponentStore] БЕЗ payload: базовый sparse set
## уже даёт всё нужное — [method EcsComponentStore.attach],
## [method EcsComponentStore.detach], [method EcsComponentStore.has] и, что
## ценнее всего, плотный массив [member EcsComponentStore.dense_entities] для
## обхода «всех сущностей категории X» на полной скорости.
##
## Виртуальные хуки переопределены явными no-op, а не унаследованы молча —
## так «это хранилище намеренно не несёт данных» видно прямо здесь.

## Нет payload-массивов — нечего выделять.
func _reserve_dense(_dense_capacity: int) -> void:
	pass


## Объявлен, чтобы EcsComponentStore автоматически определил поддержку роста:
## тег всегда переживает world.reserve_capacity(), поскольку своих данных для
## переноса у него нет.
func _grow_dense(_previous_capacity: int, _dense_capacity: int) -> void:
	pass


## Нет payload-массивов — нечего переносить при swap-remove.
func _relocate_dense(_from_slot: int, _to_slot: int) -> void:
	pass


## Специализированное пакетное удаление. У тега нет payload, поэтому здесь
## вообще нет переноса — ни виртуального вызова на каждое перемещение, как в
## обычном пути, ни записи перемещений, как в пакетном.
func detach_many(entities: PackedInt32Array, entity_count: int) -> int:
	if entity_count <= 0 or count == 0:
		return 0
	if entity_count > entities.size():
		push_error("EcsTagStore(тип %d): detach_many() получил count %d при размере массива %d"
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


## Специализированное удаление по флагам — по той же причине, что и
## [method detach_many]: переносить нечего, поэтому исчезает и вызов на каждое
## удаление.
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
