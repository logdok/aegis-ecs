class_name EcsView
extends RefCounted

## A non-materialized store intersection with no allocation at all.
##
## [method configure] is a cold operation. Each frame [method refresh_driver]
## picks the smallest of the required sparse sets, and [method matches] runs
## direct membership checks without building an iterator or a result array.
##
## [b]In the hottest systems it is better not to use [method matches] at all.[/b]
## It is a method call per candidate, and at tens of thousands of entities that
## is the main cost. Take the RESOLVED stores from the view once, lift their
## sparse arrays into local variables and inline the check into your own loop:
## [codeblock]
## view.refresh_driver()
## var driver := view.get_candidate_store()
## var candidates: PackedInt32Array = driver.dense_entities
## var health_slots: PackedInt32Array = view.get_required_sparse(1)
## for dense in driver.count:
##     var entity: int = candidates[dense]
##     var health_slot: int = health_slots[entity]
##     if health_slot == -1:
##         continue
##     ...
## [/codeblock]

var _world: EcsWorld
var _owner_system: EcsSystem
var _required: Array[EcsComponentStore] = []
var _excluded: Array[EcsComponentStore] = []
var _driver: EcsComponentStore
var _driver_index: int = -1
var _configured: bool = false


func configure(
	world: EcsWorld,
	required_types: PackedInt32Array,
	excluded_types: PackedInt32Array = PackedInt32Array(),
	owner_system: EcsSystem = null,
) -> bool:
	_required.clear()
	_excluded.clear()
	_driver = null
	_driver_index = -1
	_configured = false
	_world = world
	_owner_system = owner_system
	if world == null or required_types.is_empty():
		push_error("EcsView: a world and at least one required type are mandatory")
		return false

	for type_id in required_types:
		if not world.has_store(type_id):
			push_error("EcsView: required type %d is not registered" % type_id)
			return false
		var store: EcsComponentStore = world.get_store(type_id)
		if _required.has(store):
			push_error("EcsView: required type %d is listed twice" % type_id)
			return false
		_required.append(store)

	for type_id in excluded_types:
		if not world.has_store(type_id):
			push_error("EcsView: excluded type %d is not registered" % type_id)
			return false
		var store: EcsComponentStore = world.get_store(type_id)
		if _required.has(store):
			push_error("EcsView: type %d is both required and excluded" % type_id)
			return false
		if _excluded.has(store):
			push_error("EcsView: excluded type %d is listed twice" % type_id)
			return false
		_excluded.append(store)

	_configured = true
	refresh_driver()
	return true


## Picks the smallest of the required stores. No allocation and no
## materialization.
func refresh_driver() -> void:
	if not _configured:
		return
	_driver = _required[0]
	_driver_index = 0
	for index in _required.size():
		if index == 0:
			continue
		if _required[index].count < _driver.count:
			_driver = _required[index]
			_driver_index = index


func matches(entity: int) -> bool:
	for store in _required:
		if store.sparse_index[entity] == -1:
			return false
	for store in _excluded:
		if store.sparse_index[entity] != -1:
			return false
	return true


func get_candidate_store() -> EcsComponentStore:
	return _driver


func get_candidate_count() -> int:
	return _driver.count if _driver != null else 0


## The index, in the required list, of the store [method refresh_driver] chose.
## Membership in it is implied by walking its own dense array, so a hand-written
## loop can skip checking it.
func get_driver_required_index() -> int:
	return _driver_index


func get_required_count() -> int:
	return _required.size()


func get_required_store(index: int) -> EcsComponentStore:
	return _required[index]


## The sparse array of required store [param index] — for inlining the membership
## check into a system's own loop. Read-only.
func get_required_sparse(index: int) -> PackedInt32Array:
	return _required[index].sparse_index


func get_excluded_count() -> int:
	return _excluded.size()


func get_excluded_store(index: int) -> EcsComponentStore:
	return _excluded[index]


## The sparse array of excluded store [param index]. Read-only.
func get_excluded_sparse(index: int) -> PackedInt32Array:
	return _excluded[index].sparse_index


func is_configured() -> bool:
	return _configured


## A metadata check only; it does not affect execution in any way. Legacy
## systems with no declarations are accepted until this method is called
## explicitly.
func validate_owner_access(report_errors: bool = true) -> bool:
	if _owner_system == null:
		return true
	if not _owner_system.access_metadata_complete:
		if report_errors:
			push_error("EcsView: system %s has not completed its access description" % _owner_system.system_name)
		return false
	var valid := true
	for store in _required:
		if not _owner_system.has_declared_access(store.type_id):
			valid = false
			if report_errors:
				push_error("EcsView: system %s did not declare access to type %d"
					% [_owner_system.system_name, store.type_id])
	for store in _excluded:
		if not _owner_system.has_declared_access(store.type_id):
			valid = false
			if report_errors:
				push_error("EcsView: system %s did not declare access to excluded type %d"
					% [_owner_system.system_name, store.type_id])
	return valid
