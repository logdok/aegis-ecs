class_name EcsQuery
extends RefCounted

## Необязательный материализованный кэш поверх [EcsView]. Буфер результата
## выделяется один раз и перестраивается только тогда, когда какое-нибудь из
## участвующих хранилищ изменило состав. Прямой цикл по хранилищу остаётся
## самым быстрым вариантом для одной горячей системы; запрос окупается, когда
## одно и то же пересечение читают несколько раз или когда оно меняется намного
## реже, чем читается.
##
## Сама перестройка поднимает все участвующие sparse-массивы в локальные
## переменные до цикла и не вызывает [method EcsView.matches] вовсе, поэтому
## стоит нескольких чтений массива на кандидата, а не вызова метода.

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

# Пересобирается на каждый refresh: sparse-массивы, которые реально нужно
# проверять. Ведущее хранилище из списка исключено — обход его плотного массива
# уже подразумевает принадлежность к нему.
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
		push_error("EcsQuery: maximum_results должен быть -1 либо положительным")
		return false
	_entities.resize(world.capacity if maximum_results == -1 else mini(maximum_results, world.capacity))
	_last_versions.resize(_tracked_stores.size())
	_last_versions.fill(-1)
	_configured = true
	return true


## Возвращает true, если кэш был перестроен, и false, если состав не менялся.
func refresh() -> bool:
	if not _configured:
		return false
	var expected_capacity: int = _world.capacity if _maximum_results == -1 \
		else mini(_maximum_results, _world.capacity)
	if _entities.size() != expected_capacity:
		# reserve_capacity() и так является явным аллоцирующим барьером, поэтому
		# подстройка запроса здесь не нарушает контракт «в кадре не аллоцируем».
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

	# Один раз разрешаем те sparse-массивы, которые действительно нужно
	# проверять.
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
		# Множество задаётся одним лишь ведущим хранилищем: прямое копирование
		# его плотного массива.
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


## Быстрый небезопасный путь: считайте возвращённый буфер только читаемым и не
## сохраняйте псевдоним через refresh()/reserve_capacity(). Действительный
## префикс — [0, count).
func get_entities_unsafe() -> PackedInt32Array:
	return _entities


func get_rebuild_count() -> int:
	return _rebuild_count


func get_result_capacity() -> int:
	return _entities.size()


func is_truncated() -> bool:
	return _truncated


## Лежащий в основе view — для систем, которым нужны разрешённые хранилища без
## материализации результата.
func get_view() -> EcsView:
	return _view


func validate_owner_access(report_errors: bool = true) -> bool:
	return _view.validate_owner_access(report_errors)
