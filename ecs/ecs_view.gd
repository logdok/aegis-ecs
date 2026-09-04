class_name EcsView
extends RefCounted

## Нематериализованное пересечение хранилищ без единой аллокации.
##
## [method configure] — холодная операция. Каждый кадр [method refresh_driver]
## выбирает наименьшую из обязательных sparse-множеств, а [method matches]
## выполняет прямые проверки принадлежности, не строя ни итератора, ни массива
## результата.
##
## [b]В самых горячих системах [method matches] лучше не использовать вовсе.[/b]
## Это вызов метода на каждого кандидата, а на десятках тысяч сущностей именно
## он и оказывается основной стоимостью. Возьмите у view РАЗРЕШЁННЫЕ хранилища
## один раз, поднимите их sparse-массивы в локальные переменные и встройте
## проверку в свой цикл:
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
		push_error("EcsView: обязательны мир и хотя бы один required-тип")
		return false

	for type_id in required_types:
		if not world.has_store(type_id):
			push_error("EcsView: required-тип %d не зарегистрирован" % type_id)
			return false
		var store: EcsComponentStore = world.get_store(type_id)
		if _required.has(store):
			push_error("EcsView: required-тип %d указан дважды" % type_id)
			return false
		_required.append(store)

	for type_id in excluded_types:
		if not world.has_store(type_id):
			push_error("EcsView: excluded-тип %d не зарегистрирован" % type_id)
			return false
		var store: EcsComponentStore = world.get_store(type_id)
		if _required.has(store):
			push_error("EcsView: тип %d одновременно required и excluded" % type_id)
			return false
		if _excluded.has(store):
			push_error("EcsView: excluded-тип %d указан дважды" % type_id)
			return false
		_excluded.append(store)

	_configured = true
	refresh_driver()
	return true


## Выбирает наименьшее из обязательных хранилищ. Без аллокаций и без
## материализации.
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


## Индекс в списке обязательных того хранилища, которое выбрал
## [method refresh_driver]. Принадлежность именно к нему подразумевается самим
## обходом его плотного массива, поэтому рукописный цикл может его не проверять.
func get_driver_required_index() -> int:
	return _driver_index


func get_required_count() -> int:
	return _required.size()


func get_required_store(index: int) -> EcsComponentStore:
	return _required[index]


## Sparse-массив обязательного хранилища [param index] — чтобы встроить проверку
## принадлежности в собственный цикл системы. Только для чтения.
func get_required_sparse(index: int) -> PackedInt32Array:
	return _required[index].sparse_index


func get_excluded_count() -> int:
	return _excluded.size()


func get_excluded_store(index: int) -> EcsComponentStore:
	return _excluded[index]


## Sparse-массив исключённого хранилища [param index]. Только для чтения.
func get_excluded_sparse(index: int) -> PackedInt32Array:
	return _excluded[index].sparse_index


func is_configured() -> bool:
	return _configured


## Только проверка метаданных; на исполнение она не влияет никак. Старые
## системы без объявлений принимаются, пока этот метод не вызван явно.
func validate_owner_access(report_errors: bool = true) -> bool:
	if _owner_system == null:
		return true
	if not _owner_system.access_metadata_complete:
		if report_errors:
			push_error("EcsView: система %s не завершила описание доступа" % _owner_system.system_name)
		return false
	var valid := true
	for store in _required:
		if not _owner_system.has_declared_access(store.type_id):
			valid = false
			if report_errors:
				push_error("EcsView: система %s не объявила доступ к типу %d"
					% [_owner_system.system_name, store.type_id])
	for store in _excluded:
		if not _owner_system.has_declared_access(store.type_id):
			valid = false
			if report_errors:
				push_error("EcsView: система %s не объявила доступ к excluded-типу %d"
					% [_owner_system.system_name, store.type_id])
	return valid
