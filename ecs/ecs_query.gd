class_name EcsQuery
extends RefCounted

## An optional materialized cache on top of [EcsView]. The result buffer is
## allocated once and rebuilt only when one of the participating stores has
## changed its membership. A direct loop over a store remains the fastest option
## for a single hot system; a query pays off when the same intersection is read
## several times, or when it changes far less often than it is read.
##
## The rebuild itself lifts all participating sparse arrays into local variables
## before the loop and does not call [method EcsView.matches] at all, so it costs
## a few array reads per candidate rather than a method call.

var count: int = 0

var _world: EcsWorld
var _view := EcsView.new()
var _entities: PackedInt32Array = PackedInt32Array()
var _tracked_stores: Array[EcsComponentStore] = []
var _last_versions: PackedInt64Array = PackedInt64Array()
var _configured: bool = false
var _rebuild_count: int = 0
var _maximum_results: int = -1
var _truncated: bool = false

# Rebuilt on every refresh: the sparse arrays that actually need checking. The
# driver store is excluded from the list — walking its dense array already
# implies membership in it.
var _test_required: Array[PackedInt32Array] = []
var _test_excluded: Array[PackedInt32Array] = []


func configure(
	world: EcsWorld,
	required_types: PackedInt32Array,
	excluded_types: PackedInt32Array = PackedInt32Array(),
	owner_system: EcsSystem = null,
	maximum_results: int = -1,
) -> bool:
	_configured = false
	_world = world
	_tracked_stores.clear()
	_entities.resize(0)
	_last_versions.resize(0)
	count = 0
	_rebuild_count = 0
	_truncated = false
	_maximum_results = maximum_results
	if not _view.configure(world, required_types, excluded_types, owner_system):
		return false
	for index in _view.get_required_count():
		_tracked_stores.append(_view.get_required_store(index))
	for index in _view.get_excluded_count():
		_tracked_stores.append(_view.get_excluded_store(index))
	if maximum_results == 0 or maximum_results < -1:
		push_error("EcsQuery: maximum_results must be -1 or positive")
		return false
	_entities.resize(world.capacity if maximum_results == -1 else mini(maximum_results, world.capacity))
	_last_versions.resize(_tracked_stores.size())
	_last_versions.fill(-1)
	_configured = true
	return true


## Returns true if the cache was rebuilt, and false if the membership did not
## change.
func refresh() -> bool:
	if not _configured:
		return false
	var expected_capacity: int = _world.capacity if _maximum_results == -1 \
		else mini(_maximum_results, _world.capacity)
	if _entities.size() != expected_capacity:
		# reserve_capacity() is already an explicit allocating barrier, so
		# adjusting the query here does not break the "no allocation in a frame"
		# contract.
		_entities.resize(expected_capacity)
	if is_current():
		return false

	_view.refresh_driver()
	var driver: EcsComponentStore = _view.get_candidate_store()
	var candidates: PackedInt32Array = driver.dense_entities
	var driver_count: int = driver.count
	var out: PackedInt32Array = _entities
	var limit: int = out.size()
	var found: int = 0
	var truncated: bool = false

	# Resolve, once, the sparse arrays that actually need checking.
	var driver_index: int = _view.get_driver_required_index()
	_test_required.clear()
	for index in _view.get_required_count():
		if index != driver_index:
			_test_required.append(_view.get_required_sparse(index))
	_test_excluded.clear()
	for index in _view.get_excluded_count():
		_test_excluded.append(_view.get_excluded_sparse(index))

	var required_tests: int = _test_required.size()
	var excluded_tests: int = _test_excluded.size()

	if required_tests == 0 and excluded_tests == 0:
		# The set is defined by the driver store alone: a direct copy of its
		# dense array.
		var copied: int = mini(driver_count, limit)
		for dense in copied:
			out[dense] = candidates[dense]
		found = copied
		truncated = driver_count > limit
	elif required_tests == 1 and excluded_tests == 0:
		var required_a: PackedInt32Array = _test_required[0]
		for dense in driver_count:
			var entity: int = candidates[dense]
			if required_a[entity] == -1:
				continue
			if found < limit:
				out[found] = entity
				found += 1
			else:
				truncated = true
				break
	elif required_tests == 0 and excluded_tests == 1:
		var excluded_a: PackedInt32Array = _test_excluded[0]
		for dense in driver_count:
			var entity: int = candidates[dense]
			if excluded_a[entity] != -1:
				continue
			if found < limit:
				out[found] = entity
				found += 1
			else:
				truncated = true
				break
	elif required_tests == 1 and excluded_tests == 1:
		var required_b: PackedInt32Array = _test_required[0]
		var excluded_b: PackedInt32Array = _test_excluded[0]
		for dense in driver_count:
			var entity: int = candidates[dense]
			if required_b[entity] == -1 or excluded_b[entity] != -1:
				continue
			if found < limit:
				out[found] = entity
				found += 1
			else:
				truncated = true
				break
	else:
		var required_list: Array[PackedInt32Array] = _test_required
		var excluded_list: Array[PackedInt32Array] = _test_excluded
		for dense in driver_count:
			var entity: int = candidates[dense]
			var matched: bool = true
			for test in required_tests:
				var sparse: PackedInt32Array = required_list[test]
				if sparse[entity] == -1:
					matched = false
					break
			if matched:
				for test in excluded_tests:
					var sparse: PackedInt32Array = excluded_list[test]
					if sparse[entity] != -1:
						matched = false
						break
			if not matched:
				continue
			if found < limit:
				out[found] = entity
				found += 1
			else:
				truncated = true
				break

	count = found
	_truncated = truncated
	for index in _tracked_stores.size():
		_last_versions[index] = _tracked_stores[index].structural_version
	_rebuild_count += 1
	return true


func is_current() -> bool:
	if not _configured:
		return false
	for index in _tracked_stores.size():
		if _last_versions[index] != _tracked_stores[index].structural_version:
			return false
	return true


func entity_at(index: int) -> int:
	return _entities[index]


## The fast, unsafe path: treat the returned buffer as read-only and do not keep
## an alias across refresh()/reserve_capacity(). The valid prefix is [0, count).
func get_entities_unsafe() -> PackedInt32Array:
	return _entities


func get_rebuild_count() -> int:
	return _rebuild_count


func get_result_capacity() -> int:
	return _entities.size()


func is_truncated() -> bool:
	return _truncated


## The underlying view — for systems that want the resolved stores without a
## materialized result.
func get_view() -> EcsView:
	return _view


func validate_owner_access(report_errors: bool = true) -> bool:
	return _view.validate_owner_access(report_errors)
