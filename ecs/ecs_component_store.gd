class_name EcsComponentStore
extends RefCounted

## Абстрактное хранилище компонентов на основе sparse set (разрежённого множества).
##
## Этот класс определяет, КАК разложены данные компонентов. Его задача — для
## произвольного набора живых сущностей (а сущности, напомним, это просто целые
## числа, см. [EcsWorld]) хранить их данные ПЛОТНО, без дыр, чтобы система могла
## обойти все сущности с этим компонентом одним циклом `for i in count`, а не
## перебирать все возможные id с вопросом «а есть ли компонент?».
##
## [b]Устройство памяти[/b] — два параллельных массива, работающих в обе стороны:
## [codeblock]
## sparse_index[entity_id] -> плотный слот, либо -1, если компонента нет
## dense_entities[slot]    -> какой сущности принадлежит этот плотный слот
## [/codeblock]
##
## Сами ДАННЫЕ компонента лежат в наследнике, в параллельных `Packed*Array`,
## адресуемых ТЕМ ЖЕ САМЫМ плотным слотом. Если сущность 42 занимает слот 5, её
## позицию надо искать по индексу 5 массива позиций наследника, а не по 42.
##
## [b]Что обязан предоставить наследник[/b]: [method _reserve_dense] (выделить
## payload-массивы) и [method _relocate_dense] (перенести данные между плотными
## слотами при swap-remove). Забыть второй — классическая ошибка: удаление
## начнёт тихо портить данные, без единого сообщения в консоли.
## [EcsPackedStore] реализует оба обобщённо и является рекомендуемой базой для
## обычных компонентов-данных.
##
## [b]Необязательные хуки определяются автоматически[/b]. Они намеренно НЕ
## объявлены здесь, чтобы [method Object.has_method] мог сказать, определил ли
## их наследник на самом деле. Определили хук — он используется; не определили —
## он не стоит вообще ничего. Флага, который можно забыть, здесь нет:
## [codeblock]
## _grow_dense(previous_capacity, new_capacity)   # разрешает world.reserve_capacity()
## _relocate_dense_batch(from_slots, to_slots, n) # пакетный перенос с выносом массивов
## _release_dense(slot)                           # освободить свой Resource/RID/Callable
## _clear_relocated_dense(slot)                   # очистить дубликат в слоте-источнике
## _clear_dense(active_count)                     # массовая очистка при clear()/reset()
## [/codeblock]
##
## [b]ПОЧЕМУ ПОЛЯ ПУБЛИЧНЫЕ[/b]: [member sparse_index], [member dense_entities]
## и [member count] намеренно не спрятаны за геттеры. Системы читают их НАПРЯМУЮ
## внутри горячих циклов, а вызов метода в GDScript стоит в несколько раз
## дороже чтения элемента массива (замерено: ~90 нс против ~20 нс). Снаружи
## считайте их ТОЛЬКО ДЛЯ ЧТЕНИЯ: писать имеет право лишь сам класс и наследники.
##
## [b]О проверке границ[/b]: [method has], [method index_of] и
## [method entity_at] намеренно НЕ проверяют аргумент — это примитивы горячего
## цикла. Структурные входы ([method attach], [method detach] и их пакетные
## формы) границы проверяют, потому что выполняются заметно реже.

## Шаг роста буферов необязательного журнала изменений.
const _CHANGE_LOG_MIN_CAPACITY: int = 64

var type_id: int = -1

## Необязательное человекочитаемое имя для инструментов. Оставьте пустым, и
## [method get_debug_name] выведет его из имени класса скрипта: хранилище,
## объявленное как `class_name PositionStore`, уже отчитается как
## «PositionStore», без всякой бухгалтерии. Задавайте явно, только чтобы это
## поведение переопределить.
var debug_name: String = ""

var sparse_index: PackedInt32Array = PackedInt32Array()
var dense_entities: PackedInt32Array = PackedInt32Array()
var count: int = 0

## Растёт при каждом изменении состава или раскладки плотных слотов. Запись в
## payload на него не влияет. [EcsQuery] использует это значение, чтобы
## пропустить перестройку неизменившегося пересечения компонентов.
var structural_version: int = 0

## Журнал структурных изменений, включаемый по желанию. Пока он включён, каждая
## сущность, получившая компонент, дописывается в [member added_entities], а
## потерявшая — в [member removed_entities], до вызова [method clear_change_log].
## Это поддерживаемый способ реагировать на «появилось» и «погибло» без опроса.
##
## Выключенным он стоит одну проверку на структурную операцию, то есть
## фактически ничего. Включение выделяет два буфера журнала, растущих удвоением,
## пока они не достигнут размера типичной кадровой текучки.
var track_changes: bool = false:
	set(value):
		track_changes = value
		if value and added_entities.size() == 0:
			added_entities.resize(_CHANGE_LOG_MIN_CAPACITY)
			removed_entities.resize(_CHANGE_LOG_MIN_CAPACITY)

## Действительный префикс — [0, added_count). Очищается [method clear_change_log].
var added_entities: PackedInt32Array = PackedInt32Array()
var added_count: int = 0

## Действительный префикс — [0, removed_count). Очищается [method clear_change_log].
var removed_entities: PackedInt32Array = PackedInt32Array()
var removed_count: int = 0

## Выставляется, когда [method clear] или [method EcsWorld.reset] очистили
## хранилище при включённом журнале. Отдельные удаления в этом случае НЕ
## записываются: полный сброс иначе прогнал бы через журнал всю популяцию.
var change_log_overflowed: bool = false

var _capacity: int = 0
var _initialized: bool = false
## Только идентификация: сильная ссылка на владельца образовала бы цикл
## RefCounted (мир -> хранилища -> мир) и утекли бы оба объекта.
var _owner_world_id: int = 0

# Необязательные хуки, определяемые один раз в initialize().
var _supports_growth: bool = false
var _has_batch_relocate: bool = false
var _tracks_ownership: bool = false
var _has_clear_relocated: bool = false
var _has_clear_dense: bool = false

# Рабочие буферы пакетного переноса, растут по необходимости.
var _move_from: PackedInt32Array = PackedInt32Array()
var _move_to: PackedInt32Array = PackedInt32Array()


## Вызывается из [method EcsWorld.register_store]. Вручную звать не нужно.
func initialize(component_type_id: int, entity_capacity: int, owner_world) -> bool:
	if _initialized:
		push_error("EcsComponentStore: initialize() вызван повторно")
		return false
	type_id = component_type_id
	_owner_world_id = owner_world.get_instance_id()
	_capacity = entity_capacity

	# Разрешаем необязательные хуки один раз. has_method() здесь точен ровно
	# потому, что этот класс ни одного из них не объявляет.
	_supports_growth = has_method(&"_grow_dense")
	_has_batch_relocate = has_method(&"_relocate_dense_batch")
	_tracks_ownership = has_method(&"_release_dense")
	_has_clear_relocated = has_method(&"_clear_relocated_dense")
	_has_clear_dense = has_method(&"_clear_dense")
	if _has_clear_relocated and not _tracks_ownership:
		push_error("EcsComponentStore(тип %d): _clear_relocated_dense() без _release_dense() — "
			% component_type_id + "слот-источник будет очищен, а удаляемые данные никогда не освободятся")

	sparse_index.resize(entity_capacity)
	sparse_index.fill(-1)
	dense_entities.resize(entity_capacity)
	count = 0
	_reserve_dense(entity_capacity)
	structural_version += 1
	_initialized = true
	return true


## True, когда наследник определил `_grow_dense()` — именно это и делает
## хранилище безопасным для [method EcsWorld.reserve_capacity].
func supports_capacity_growth() -> bool:
	return _supports_growth


## Внутренняя половина EcsWorld.reserve_capacity(). Прямой рост отдельного
## хранилища намеренно невозможен: ёмкость каждого обязана совпадать с
## ёмкостью мира-владельца.
func _can_grow_capacity_from_world(dense_capacity: int, owner_world) -> bool:
	return owner_world != null \
		and owner_world.get_instance_id() == _owner_world_id \
		and dense_capacity > _capacity \
		and _supports_growth


func _commit_capacity_growth_from_world(dense_capacity: int, owner_world) -> void:
	# EcsWorld один раз выполняет полную предпроверку до изменения любого буфера.
	# Этот коммит намеренно не перепроверяет возможность повторно, чтобы хук с
	# внутренним состоянием не мог создать частично применённую транзакцию.
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


## [b]Обязательное переопределение.[/b] Выделить (resize) payload-массивы
## наследника под [param dense_capacity] элементов. Базовый класс не может
## сделать это за него, потому что не знает, какие данные тот хранит.
func _reserve_dense(_dense_capacity: int) -> void:
	pass


## [b]Обязательное переопределение.[/b] Скопировать ДАННЫЕ компонента с плотного
## слота [param from_slot] на [param to_slot]. Сами id сущностей переносит
## базовый класс. Вызывается при swap-remove, например:
## `position[to_slot] = position[from_slot]`.
func _relocate_dense(_from_slot: int, _to_slot: int) -> void:
	pass


## Присоединяет компонент к [param entity] и возвращает его плотный слот.
## Идемпотентно: если компонент уже присоединён, возвращается существующий слот.
## Возвращает -1, когда ёмкость исчерпана или id вне диапазона.
##
## Новый слот всегда дописывается в КОНЕЦ плотного массива — именно это и
## держит массив непрерывным от 0 до count-1.
func attach(entity: int) -> int:
	if entity < 0 or entity >= _capacity:
		push_error("EcsComponentStore(тип %d): сущность %d вне ёмкости" % [type_id, entity])
		return -1
	var existing: int = sparse_index[entity]
	if existing != -1:
		return existing
	if count >= _capacity:
		push_error("EcsComponentStore(тип %d): плотная ёмкость исчерпана" % type_id)
		return -1
	var slot: int = count
	sparse_index[entity] = slot
	dense_entities[slot] = entity
	count = slot + 1
	structural_version += 1
	if track_changes:
		_push_added(entity)
	return slot


## Присоединяет компонент к [param entity_count] сущностям из [param entities]
## за один проход и возвращает, скольким он был присоединён впервые.
##
## Это спавн-аналог [method detach_many]: накладные расходы на хранилище
## платятся один раз, а не на каждую сущность. Сущности, у которых компонент
## уже есть, пропускаются.
##
## [b]Раскладка слотов[/b]: новые компоненты занимают плотные слоты
## `[old_count, old_count + attached)` в том порядке, в каком сущности идут в
## [param entities]. Снимите [member count] ДО вызова, чтобы получить
## `old_count`, и пишите данные прямо в эти слоты:
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
		push_error("EcsComponentStore(тип %d): attach_many() получил count %d при размере массива %d"
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
			push_error("EcsComponentStore(тип %d): сущность %d вне ёмкости" % [type_id, entity])
			continue
		if sparse[entity] != -1:
			continue
		if live >= limit:
			push_error("EcsComponentStore(тип %d): плотная ёмкость исчерпана" % type_id)
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


## Отсоединяет компонент от [param entity]. Безопасно вызывать, даже если
## такого компонента у сущности нет — тогда это no-op.
##
## [b]SWAP-REMOVE[/b] — то, ради чего вообще нужен sparse set. Чтобы удалить
## элемент из СЕРЕДИНЫ плотного массива, не оставив дыру и не сдвигая хвост
## (это было бы O(n) на удаление), на освободившееся место переносится
## ПОСЛЕДНИЙ элемент:
## [codeblock]
## 1. slot = освобождаемый плотный слот (он принадлежал `entity`)
## 2. last = индекс последнего занятого слота (count - 1)
## 3. если slot != last: скопировать данные с last на slot (_relocate_dense),
##    затем перенаправить ОБА отображения переехавшей сущности на новый слот
## 4. пометить `entity` как не имеющую компонента и уменьшить count
## [/codeblock]
## Стоимость — O(1) независимо от размера массива. Расплата: порядок в плотном
## массиве НЕ сохраняется, поэтому системы не должны зависеть от порядка обхода.
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


## Отсоединяет компонент от [param entity_count] сущностей из [param entities]
## за один проход и возвращает, сколько компонентов реально удалено.
##
## [b]Это и есть пакетный путь уничтожения[/b], и причина, по которой
## [method EcsWorld.flush_destroy_queue] идёт по хранилищам, а не по сущностям.
## Цикл здесь позволяет держать sparse/dense-массивы в локальных переменных, и
## сущность, у которой этого компонента НЕТ, стоит одного чтения локального
## массива вместо чтения поля объекта плюс вызова метода. При дюжине хранилищ
## у большинства сущностей нет большинства компонентов, поэтому именно этот
## путь пропуска и определяет суммарную стоимость.
##
## Семантика идентична вызову [method detach] для каждой сущности по порядку.
func detach_many(entities: PackedInt32Array, entity_count: int) -> int:
	if entity_count <= 0 or count == 0:
		return 0
	if entity_count > entities.size():
		push_error("EcsComponentStore(тип %d): detach_many() получил count %d при размере массива %d"
			% [type_id, entity_count, entities.size()])
		entity_count = entities.size()

	var sparse: PackedInt32Array = sparse_index
	var dense: PackedInt32Array = dense_entities
	# Вынесено из циклов ниже: чтение свойства `self` стоит в несколько раз
	# дороже индексного чтения локальной переменной, а это выполняется один раз
	# на каждую пару (сущность, хранилище).
	var limit: int = _capacity
	var live: int = count
	var removed: int = 0
	var log_changes: bool = track_changes
	if log_changes:
		_reserve_removed(removed_count + entity_count)
	var log: PackedInt32Array = removed_entities
	var logged: int = removed_count

	if _tracks_ownership:
		# Данные, которыми хранилище владеет, обязаны быть освобождены ДО того,
		# как их что-либо перезапишет, поэтому здесь перенос обязан оставаться
		# чередующимся с обновлением отображений.
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
		# Отсутствие хуков владения означает, что по ходу цикла payload никто не
		# читает, поэтому все перемещения можно записать и применить потом одним
		# проходом. Применение в порядке записи в точности эквивалентно
		# чередованию, зато позволяет наследнику вынести поиск своих массивов из
		# цикла по перемещениям.
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


## Отсоединяет каждую сущность, у которой байт в [param flags] ненулевой, и
## возвращает, сколько компонентов удалено.
##
## Это вторая половина пакетного пути уничтожения. [method detach_many] стоит
## O(жертвы) на каждое хранилище, что расточительно для хранилища, намного
## меньшего списка жертв: хранилище «турель» с одним компонентом всё равно
## проходило десять тысяч жертв. Эта форма стоит O(count), поэтому
## [method EcsWorld.flush_destroy_queue] выбирает тот список, который короче.
## При схеме из множества специализированных мелких хранилищ это разница между
## O(жертвы x хранилища) и O(сумма размеров хранилищ).
##
## [param flags] индексируется id сущности и должен быть не короче ёмкости
## хранилища. Порядок удаления не определён — не полагайтесь на него, в том
## числе в журнале изменений.
##
## [b]Кроме того, здесь выполняется теоретический минимум перемещений.[/b] Зная
## заранее, какие сущности обречены, метод никогда не переносит обречённый
## элемент в только что освободившийся слот лишь для того, чтобы через мгновение
## удалить его снова: сначала помеченные элементы срезаются с хвоста, и реальное
## перемещение происходит, только когда дыру нужно заполнить выжившим. Поэтому
## уничтожение всей популяции — перезапуск уровня, выбитая волна — выполняет
## НОЛЬ перемещений, тогда как путь по списку жертв делает по одному на удаление.
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
		# Сначала срезаем помеченные элементы с хвоста. На их место ничему
		# перемещаться не нужно, поэтому каждый стоит одной записи в sparse.
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

		# Этот слот обречён, а хвостовой элемент — выживший, значит это
		# перемещение, которое действительно необходимо.
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
		# Только что записанный сюда выживший заведомо не помечен, поэтому слот
		# не нужно перепроверять.
		slot += 1

	count = live
	removed_count = logged
	if removed > 0:
		structural_version += 1
	return removed


func has(entity: int) -> bool:
	return sparse_index[entity] != -1


## Плотный слот сущности, либо -1, если такого компонента у неё нет.
func index_of(entity: int) -> int:
	return sparse_index[entity]


## Сущность, которой принадлежит плотный слот [param dense_slot].
func entity_at(dense_slot: int) -> int:
	return dense_entities[dense_slot]


## Опустошает хранилище без единой аллокации: сбрасывает [member sparse_index]
## и [member count]. Данные физически остаются на месте, но становятся
## недостижимы — при count == 0 их не видит ни одна система, а следующий
## [method attach] их перезапишет.
##
## Отдельные удаления в журнал изменений не пишутся; вместо этого поднимается
## [member change_log_overflowed], потому что прогонять через журнал всю
## популяцию при перезапуске уровня вызывающему коду никогда не нужно.
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


## Сбрасывает всё, накопленное с прошлого вызова. Вызывайте один раз за кадр,
## после того как отработали системы, потребляющие журнал.
func clear_change_log() -> void:
	added_count = 0
	removed_count = 0
	change_log_overflowed = false


## Имя для диагностики и отладочного интерфейса. Только холодный путь.
##
## Откатывается к глобальному имени класса скрипта, затем к «type N», чтобы
## инструментам никогда не приходилось показывать голое число, а хранилищам —
## получать аннотацию вручную.
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


## Дорогая проверка инвариантов для этапа разработки. Намеренно вызывается по
## желанию и не аллоцирует ничего, кроме строк ошибок в push_error().
func validate_integrity(alive: PackedByteArray = PackedByteArray(), report_errors: bool = true) -> bool:
	var valid := true
	if count < 0 or count > _capacity:
		valid = false
		if report_errors:
			push_error("EcsComponentStore(тип %d): count %d вне ёмкости %d" % [type_id, count, _capacity])
	if sparse_index.size() != _capacity or dense_entities.size() != _capacity:
		valid = false
		if report_errors:
			push_error("EcsComponentStore(тип %d): размер sparse/dense не совпадает с ёмкостью" % type_id)
		return false
	if not alive.is_empty() and alive.size() != _capacity:
		valid = false
		if report_errors:
			push_error("EcsComponentStore(тип %d): размер alive не совпадает с ёмкостью" % type_id)
		return false

	for dense_slot in clampi(count, 0, _capacity):
		var entity: int = dense_entities[dense_slot]
		if entity < 0 or entity >= _capacity:
			valid = false
			if report_errors:
				push_error("EcsComponentStore(тип %d): плотный слот %d содержит неверную сущность %d" % [type_id, dense_slot, entity])
			continue
		if sparse_index[entity] != dense_slot:
			valid = false
			if report_errors:
				push_error("EcsComponentStore(тип %d): нарушено dense->sparse для сущности %d" % [type_id, entity])
		if not alive.is_empty() and alive[entity] == 0:
			valid = false
			if report_errors:
				push_error("EcsComponentStore(тип %d): компонент прикреплён к мёртвой сущности %d" % [type_id, entity])

	for entity in _capacity:
		var dense_slot: int = sparse_index[entity]
		if dense_slot == -1:
			continue
		if dense_slot < 0 or dense_slot >= count or dense_slot >= _capacity:
			valid = false
			if report_errors:
				push_error("EcsComponentStore(тип %d): sparse-слот %d вне count для сущности %d" % [type_id, dense_slot, entity])
			continue
		if dense_entities[dense_slot] != entity:
			valid = false
			if report_errors:
				push_error("EcsComponentStore(тип %d): нарушено sparse->dense для сущности %d" % [type_id, entity])
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
