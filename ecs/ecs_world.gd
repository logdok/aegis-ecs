class_name EcsWorld
extends RefCounted

## Распределитель сущностей и реестр хранилищ компонентов.
##
## Сущность здесь — это НЕ объект и не класс, а просто целое число (индекс).
## Сама по себе сущность не хранит никаких данных: данные лежат в хранилищах
## компонентов ([EcsComponentStore]), а сущность служит лишь ключом, по которому
## эти хранилища индексируются. Это и есть суть ECS: Entity — просто id,
## Component — чистые данные, System — чистая логика над этими данными. Игровые
## объекты при таком подходе не являются нодами Godot: вся симуляция работает
## поверх плоских массивов.
##
## Мир не растёт сам: ёмкость фиксируется при создании, а редкий явный рост
## выполняется только через [method reserve_capacity] на loading barrier. Между
## такими барьерами внутренние массивы переиспользуются без аллокаций. Это
## осознанное решение: скрытая аллокация в горячем цикле при десятках тысяч
## сущностей даёт всплески кадра на слабом мобильном устройстве.
##
## [b]МОДЕЛЬ УНИЧТОЖЕНИЯ — САМОЕ ВАЖНОЕ В ЭТОМ ФАЙЛЕ.[/b]
## Ничто и никогда не уничтожается «по месту», прямо в момент вызова. Любой код,
## который хочет убить сущность, зовёт [method queue_destroy] — это только
## ПОМЕЧАЕТ её и не трогает данные. Реальное удаление делает
## [method flush_destroy_queue], и выполняться оно должно в ОДНОЙ, заранее
## известной точке кадра — обычно из последней системы конвейера (см.
## [EcsReaperSystem], который существует ровно для того, чтобы вам не пришлось
## писать эту систему самому).
##
## Зачем так? Если бы уничтожение было мгновенным, внутри одного кадра могло бы
## произойти следующее: система A прочитала сущность E и держит её плотный слот,
## затем система B уничтожила E, и этот слот через swap-remove достался ДРУГОЙ
## сущности (см. [EcsComponentStore]). Система A прочитала бы данные,
## принадлежащие уже кому-то другому — классический use-after-free, только
## ничего не падает: данные просто тихо неверные. Откладывание уничтожения в
## одну точку кадра исключает этот сценарий полностью: ни один плотный слот,
## полученный в начале кадра, не может протухнуть до его конца.
##
## В горячих циклах сущность остаётся сырым int, поэтому массивы индексируются
## без декодирования и без проверки поколения. Для ссылок, переживающих кадр
## (цель, владелец, колбек), используйте generational handle из
## [method make_handle] или [method create_entity_handle]. После уничтожения
## сущности и повторной выдачи того же сырого id старый handle гарантированно
## не разрешится.
##
## [method flush_destroy_queue] — structural sync point. Он может стоять на
## нескольких явно заданных границах фаз, но только там, где ни одна система не
## держит плотный слот: swap-remove может передвинуть другой компонент.

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

# Очередь уничтожения хранит рядом с сырым id штамп поколения, чтобы протухшая
# запись не могла воскресить уже переиспользованный слот. Разделение на два
# массива Int32 (вместо одного упакованного ключа Int64) стоит той же памяти и
# позволяет flush_destroy_queue() уплотнить разрешённых жертв на месте, без
# вспомогательного массива.
var _destroy_queue: PackedInt32Array = PackedInt32Array()
var _destroy_generation: PackedInt32Array = PackedInt32Array()
var _destroy_flag: PackedByteArray = PackedByteArray()
var _destroy_count: int = 0
var _generations: PackedInt32Array = PackedInt32Array()
var _retired: PackedByteArray = PackedByteArray()
var _retired_count: int = 0
var _world_tag: int = 0

## Монотонный диагностический счётчик создания, уничтожения, сброса,
## регистрации хранилищ и явного роста ёмкости.
var structural_version: int = 0


## [param entity_capacity] — число одновременно живых сущностей. Буферы
## выделяются сразу; редкий явный рост идёт через [method reserve_capacity] на
## loading barrier. Автоматического роста в горячем цикле нет.
func _init(entity_capacity: int) -> void:
	if entity_capacity < 1 or entity_capacity > _HANDLE_ENTITY_MASK + 1:
		push_error("EcsWorld: начальная ёмкость %d вне диапазона 1..%d; создан безопасный мир с ёмкостью 1"
			% [entity_capacity, _HANDLE_ENTITY_MASK + 1])
		capacity = 1
	else:
		capacity = entity_capacity
	if _next_world_tag > _HANDLE_WORLD_MASK:
		push_error("EcsWorld: теги миров в процессе исчерпаны; generational handle недоступны")
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


## Регистрирует [param store] под идентификатором [param component_type_id] и
## инициализирует его (выделяя внутренние массивы под текущую ёмкость мира).
## Каждое хранилище должно быть зарегистрировано ровно один раз, до создания
## первой сущности — обычно все вместе, в одном месте сборки мира.
##
## Идентификатор типа — любое целое на ваш выбор (обычно константа из вашего
## перечисления). Мир использует его только для [method get_store] и
## диагностики; на скорость он не влияет.
func register_store(store: EcsComponentStore, component_type_id: int) -> bool:
	if _schema_locked:
		push_error("EcsWorld: схема заблокирована первым create_entity(); регистрируйте хранилища заранее")
		return false
	if store == null:
		push_error("EcsWorld: register_store() получил null")
		return false
	if _stores_by_type.has(component_type_id):
		push_error("EcsWorld: тип компонента %d уже зарегистрирован — проверьте, не продублирована ли константа типа"
			% component_type_id)
		return false
	if _stores.has(store) or store.is_initialized():
		push_error("EcsWorld: хранилище уже зарегистрировано под другим типом или в другом мире")
		return false
	if not store.initialize(component_type_id, capacity, self):
		return false
	_stores.append(store)
	_stores_by_type[component_type_id] = store
	structural_version += 1
	return true


## Возвращает зарегистрированное хранилище по идентификатору типа, либо null.
##
## Предназначен для сборки мира, отладки и инструментов. В горячем цикле системы
## так делать НЕ нужно: держите типизированную ссылку на хранилище в своём
## объекте-контексте и обращайтесь к ней напрямую — это и быстрее (нет поиска по
## словарю), и статически типизировано.
func get_store(component_type_id: int) -> EcsComponentStore:
	return _stores_by_type.get(component_type_id)


func has_store(component_type_id: int) -> bool:
	return _stores_by_type.has(component_type_id)


## Выделяет новый id сущности из пула свободных. Возвращает -1, когда свободных
## id не осталось (мир заполнен под завязку) — вызывающий код обязан это
## проверять, а не считать, что создание всегда удаётся. Про рост мира до того,
## как это случится, см. [EcsCapacityPolicySystem].
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


## Выделяет до [param entity_count] сущностей за один проход, записывая их id в
## [param out_entities], и возвращает, сколько реально создано (меньше
## запрошенного, если у мира закончились свободные id).
##
## Это спавн-аналог [method flush_destroy_queue]: спавнер волны, всплеск частиц
## или шаг деления клеток создают за кадр десятки и сотни сущностей, и заплатить
## накладные расходы вызова один раз вместо N — чистый выигрыш.
## [param out_entities] должен быть заранее рассчитан на запрос; он заполняется
## на месте.
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
		push_error("EcsWorld: выходной буфер create_entities() вмещает %d, а нужно %d"
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


## Создаёт сущность и сразу возвращает handle, безопасный между кадрами.
## Перед индексированием хранилищ разрешите его через entity_from_handle().
func create_entity_handle() -> int:
	if _world_tag == 0:
		return INVALID_HANDLE
	var entity: int = create_entity()
	return make_handle(entity) if entity >= 0 else INVALID_HANDLE


## Упаковывает сырой id сущности и текущее поколение в положительное 64-битное
## число. Возвращает INVALID_HANDLE, если сущность не жива.
func make_handle(entity: int) -> int:
	if _world_tag == 0 or not is_alive(entity):
		return INVALID_HANDLE
	return (int(_world_tag) << _HANDLE_WORLD_SHIFT) \
		| (int(_generations[entity]) << _HANDLE_GENERATION_SHIFT) \
		| entity


## Разрешает handle в текущий сырой id, либо INVALID_ENTITY, если он протух.
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


## Безопасная точка входа для уничтожения целей и владельцев, хранимых между
## кадрами. Возвращает false для неверного или уже протухшего handle.
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


## Помечает [param entity] на уничтожение. НЕ удаляет её — реальное удаление
## делает [method flush_destroy_queue] в конце кадра.
##
## Идемпотентно: если сущность уже в очереди (или уже мертва), повторный вызов
## ничего не делает. Это защищает от двойной постановки в очередь, когда
## несколько систем в одном кадре независимо решают уничтожить одну и ту же
## сущность.
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


## Помечает на уничтожение [param entity_count] сущностей из [param entities] и
## возвращает, сколько из них попало в очередь впервые.
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


## Выполняет РЕАЛЬНОЕ уничтожение всех сущностей, накопленных в очереди: каждая
## отцепляется от каждого зарегистрированного хранилища, помечается мёртвой и
## возвращается в пул свободных. Возвращает число уничтоженных сущностей.
##
## Это structural sync point — вызывайте его только между фазами, когда ни одна
## система не держит плотный слот. Повторный пустой flush безопасен.
##
## [b]Цикл идёт по хранилищам, а не по сущностям.[/b] Вместо того чтобы опрашивать
## каждое хранилище о каждой сущности (чтение свойства плюс вызов метода на
## пару), каждому хранилищу один раз отдаётся весь список жертв, и оно крутит
## собственный плотный цикл (см. [method EcsComponentStore.detach_many]). При
## дюжине хранилищ у большинства сущностей нет большинства компонентов, поэтому
## всё решает путь «такого компонента нет» — а он падает с вызова метода до
## одного чтения локального массива.
func flush_destroy_queue() -> int:
	var queued: int = _destroy_count
	_destroy_count = 0
	if queued == 0:
		return 0

	# Разрешаем ключи из очереди и уплотняем выживших в начало того же массива,
	# который дальше и служит списком жертв, отдаваемым хранилищам.
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
			# Защитная ветка: внутри одного цикла flush помеченная сущность всегда
			# разрешается, поскольку поколения меняются только здесь. Флаг всё равно
			# сбрасываем, чтобы протухший не пережил цикл.
			if entity >= 0 and entity < capacity:
				flags[entity] = 0
			continue
		queue[reaped] = entity
		reaped += 1
	if reaped == 0:
		return 0

	# Флаги жертв остаются выставленными на всё время этого цикла, чтобы каждое
	# хранилище могло выбрать более дешёвый из двух обходов.
	#
	# Обход собственного плотного массива (detach_flagged) стоит O(count), но
	# заранее знает, какие элементы обречены, поэтому переносит минимум — ноль,
	# когда хранилище вычищается целиком. Обход списка жертв (detach_many) стоит
	# O(reaped), но переносит по одному разу на удаление. Хранилище выигрывает,
	# пока оно ненамного больше списка жертв; примерно после двукратного размера
	# лишние итерации перевешивают сэкономленные переносы, потому что при таком
	# размере удаляется лишь малая доля хранилища.
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


## Доля мира, занятая живыми сущностями, в [0, 1]. На ней работает
## [EcsCapacityPolicySystem], и её удобно показывать на отладочном HUD.
func get_load_factor() -> float:
	return float(_live_count) / float(capacity)


## Число зарегистрированных хранилищ компонентов.
func get_store_count() -> int:
	return _stores.size()


func get_store_at(index: int) -> EcsComponentStore:
	return _stores[index]


func is_schema_locked() -> bool:
	return _schema_locked


## Очищает журнал структурных изменений у каждого зарегистрированного хранилища,
## у которого он включён. Вызывайте один раз за кадр, после того как отработали
## системы, потребляющие журналы.
func clear_change_logs() -> void:
	for store in _stores:
		if store.track_changes:
			store.clear_change_log()


## Явно увеличивает все буферы мира и хранилищ. Существующие сырые id, handle и
## плотные слоты остаются действительными. Операция аллоцирует; вызывайте её
## только на безопасной границе загрузки, никогда — во время обхода систем.
##
## Возвращает false, ничего не тронув, если хотя бы одно зарегистрированное
## хранилище не умеет расти: хранилище поддерживает рост ровно тогда, когда оно
## определяет `_grow_dense()`. [EcsPackedStore] и [EcsTagStore] умеют всегда.
func reserve_capacity(entity_capacity: int) -> bool:
	if entity_capacity <= capacity:
		return false
	if entity_capacity > _HANDLE_ENTITY_MASK + 1:
		push_error("EcsWorld: ёмкость выходит за диапазон generational handle")
		return false
	for store in _stores:
		if store.get_capacity() != capacity \
				or not store._can_grow_capacity_from_world(entity_capacity, self):
			push_error("EcsWorld: хранилище типа %d не может безопасно вырасти до %d — ему нужен хук _grow_dense()"
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


## Полностью сбрасывает мир — все сущности «умирают», все хранилища очищаются —
## без единой аллокации: массивы просто перезаполняются. Пригодно для
## перезапуска уровня без пересоздания мира и потери преаллоцированной памяти.
##
## Регистрации хранилищ сохраняются, поэтому [method register_store] повторно
## вызывать нельзя (и не нужно).
func reset() -> void:
	_destroy_count = 0
	_free_count = 0
	_retired_count = 0
	# Свободный список заполняется по убыванию, поэтому id выдаются по возрастанию
	# (стек LIFO: записанный последним выдаётся первым). Слот с исчерпанным
	# поколением остаётся retired навсегда, чтобы старый handle не мог ожить.
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


## Дорогая проверка распределителя, очереди уничтожения и всех sparse-множеств
## для этапа разработки. Вызывайте из тестов, редакторской команды или редкой
## отладочной системы; никогда — из продакшн-кадра.
func validate_integrity(report_errors: bool = true) -> bool:
	var valid := true
	if _alive.size() != capacity or _free_ids.size() != capacity \
			or _destroy_queue.size() != capacity or _destroy_generation.size() != capacity \
			or _destroy_flag.size() != capacity \
			or _generations.size() != capacity or _retired.size() != capacity:
		if report_errors:
			push_error("EcsWorld: размеры буферов жизненного цикла не совпадают с ёмкостью")
		return false
	if _live_count < 0 or _free_count < 0 or _retired_count < 0 \
			or _live_count + _free_count + _retired_count != capacity:
		valid = false
		if report_errors:
			push_error("EcsWorld: счётчики live/free/retired не сходятся с ёмкостью")
	if _destroy_count < 0 or _destroy_count > capacity:
		valid = false
		if report_errors:
			push_error("EcsWorld: destroy_count вне ёмкости")

	var free_seen := PackedByteArray()
	free_seen.resize(capacity)
	for index in clampi(_free_count, 0, capacity):
		var entity: int = _free_ids[index]
		if entity < 0 or entity >= capacity:
			valid = false
			if report_errors:
				push_error("EcsWorld: список свободных содержит неверную сущность %d" % entity)
			continue
		if free_seen[entity] == 1 or _alive[entity] == 1:
			valid = false
			if report_errors:
				push_error("EcsWorld: дубликат или живая сущность %d в списке свободных" % entity)
		free_seen[entity] = 1

	var destroy_seen := PackedByteArray()
	destroy_seen.resize(capacity)
	for index in clampi(_destroy_count, 0, capacity):
		var entity: int = _destroy_queue[index]
		if entity < 0 or entity >= capacity:
			valid = false
			if report_errors:
				push_error("EcsWorld: очередь уничтожения содержит неверную сущность %d" % entity)
			continue
		if destroy_seen[entity] == 1 or _alive[entity] == 0 or _destroy_flag[entity] == 0:
			valid = false
			if report_errors:
				push_error("EcsWorld: неконсистентная сущность %d в очереди уничтожения" % entity)
		destroy_seen[entity] = 1

	var counted_alive: int = 0
	for entity in capacity:
		if _generations[entity] <= 0:
			valid = false
			if report_errors:
				push_error("EcsWorld: нулевое поколение у сущности %d" % entity)
		if _alive[entity] == 1:
			if _retired[entity] == 1:
				valid = false
				if report_errors:
					push_error("EcsWorld: выведенная из обращения сущность %d помечена живой" % entity)
			counted_alive += 1
		elif free_seen[entity] == 0 and _retired[entity] == 0:
			valid = false
			if report_errors:
				push_error("EcsWorld: мёртвая сущность %d отсутствует в списке свободных" % entity)
		if _destroy_flag[entity] != destroy_seen[entity]:
			valid = false
			if report_errors:
				push_error("EcsWorld: флаг уничтожения не совпадает с очередью для сущности %d" % entity)
		if _retired[entity] == 1 and free_seen[entity] == 1:
			valid = false
			if report_errors:
				push_error("EcsWorld: выведенная из обращения сущность %d присутствует в списке свободных" % entity)
	if counted_alive != _live_count:
		valid = false
		if report_errors:
			push_error("EcsWorld: флаги alive не совпадают с live_count")

	for store in _stores:
		if store.get_capacity() != capacity or not store.validate_integrity(_alive, report_errors):
			valid = false
	return valid


func _next_generation(current: int) -> int:
	var next: int = current + 1
	return 0 if next <= 0 or next > _HANDLE_GENERATION_MASK else next
