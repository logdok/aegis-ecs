class_name EcsPackedStore
extends EcsComponentStore

## Декларативное хранилище компонентов: вы объявляете поля данных, а базовый
## класс пишет всю обвязку.
##
## [EcsComponentStore] требует руками писать [method _reserve_dense] и
## [method _relocate_dense] для каждого хранилища, и забытый второй метод тихо
## портит данные при каждом удалении. Этот наследник убирает целый класс
## ошибок: назовите свои поля один раз, и всё выделение памяти, рост ёмкости и
## перенос при swap-remove будут сделаны за вас.
##
## [codeblock]
## class_name PositionStore
## extends EcsPackedStore
##
## var x: PackedFloat32Array = PackedFloat32Array()
## var y: PackedFloat32Array = PackedFloat32Array()
## var tint: PackedColorArray = PackedColorArray()
##
## func _init() -> void:
##     track(&"x", &"y", &"tint")
## [/codeblock]
##
## [b]В горячем цикле это ничего не стоит.[/b] Поля остаются обычными
## типизированными членами класса, поэтому система читает их напрямую и на
## полной скорости:
## [codeblock]
## var px: PackedFloat32Array = positions.x
## for dense in positions.count:
##     px[dense] += 1.0
## [/codeblock]
## Обобщённая работа происходит только при выделении памяти и удалении, и даже
## там базовый класс разрешает каждое поле один раз на всю операцию, а затем
## идёт по перемещениям — это измеримо быстрее, чем виртуальный вызов на каждое
## перемещение, который платит рукописное хранилище.
##
## [b]Поддерживаемые типы полей[/b]: любой `Packed*Array`, а также обычный
## `Array` для данных с объектами или ресурсами. Поле-`Array`, ВЛАДЕЮЩЕЕ тем, на
## что ссылается, должно дополнительно определить [code]_release_dense()[/code]
## (см. [EcsComponentStore]).
##
## [b]Если вы когда-нибудь присвоите отслеживаемому полю новый массив целиком[/b]
## (`x = PackedFloat32Array()`), а не измените его на месте — вызовите после
## этого [method refresh_tracked_arrays], чтобы закешированные ссылки указывали
## на новые массивы.

var _tracked_names: Array[StringName] = []
var _tracked_arrays: Array = []
var _tracked_zeros: Array = []


## Регистрирует поля данных по именам. Вызывается один раз из `_init()`.
## Принимает сколько угодно имён, поэтому хранилищу обычно хватает одной строки.
func track(
	first: StringName,
	second: StringName = &"",
	third: StringName = &"",
	fourth: StringName = &"",
	fifth: StringName = &"",
	sixth: StringName = &"",
	seventh: StringName = &"",
	eighth: StringName = &"",
) -> void:
	for name in [first, second, third, fourth, fifth, sixth, seventh, eighth]:
		if name != &"":
			track_field(name)


## Регистрирует одно поле данных. Пригодится, когда полей больше, чем принимает
## [method track], или когда имена вычисляются.
func track_field(field_name: StringName) -> void:
	if _tracked_names.has(field_name):
		push_error("EcsPackedStore: поле «%s» зарегистрировано дважды" % field_name)
		return
	var value: Variant = get(field_name)
	if value == null:
		push_error("EcsPackedStore: у этого хранилища нет поля с именем «%s»" % field_name)
		return
	var zero: Variant = _zero_for(typeof(value))
	if zero == null and typeof(value) != TYPE_ARRAY:
		push_error("EcsPackedStore: поле «%s» имеет тип %s, а это не Packed*Array и не Array"
			% [field_name, type_string(typeof(value))])
		return
	_tracked_names.append(field_name)
	_tracked_arrays.append(value)
	_tracked_zeros.append(zero)


## Заново разрешает закешированные ссылки на массивы из живых полей. Нужен
## только в редком случае, когда отслеживаемому полю присвоили новый массив
## целиком, а не меняли его на месте.
func refresh_tracked_arrays() -> void:
	for i in _tracked_names.size():
		_tracked_arrays[i] = get(_tracked_names[i])


## Число зарегистрированных полей данных. Пригодится в тестах и инструментах.
func get_tracked_field_count() -> int:
	return _tracked_names.size()


func get_tracked_field_name(index: int) -> StringName:
	return _tracked_names[index]


## Обобщённо читает одно значение данных — для отладочного интерфейса и
## инструментов.
##
## Именно это позволяет инспектору вывести компонент целиком, ничего не зная о
## хранилище: имена полей уже зарегистрированы, а здесь берутся значения.
## Только чтение, намеренно: обобщённого сеттера нет, потому что запись в живую
## симуляцию из отладочной панели — отдельное решение с другими правилами
## безопасности.
##
## Холодный путь: идёт через контейнер с Variant-типизацией. Никогда не
## вызывайте это из системы.
func get_field_value(field_index: int, dense_slot: int) -> Variant:
	if field_index < 0 or field_index >= _tracked_arrays.size():
		return null
	if dense_slot < 0 or dense_slot >= count:
		return null
	var array: Variant = _tracked_arrays[field_index]
	return array[dense_slot]


## Удобство для инструментов: все отслеживаемые поля одной сущности в виде
## `{ имя_поля: значение }`, либо пустой словарь, если компонента у сущности нет.
func describe_entity(entity: int) -> Dictionary:
	var result: Dictionary = {}
	if entity < 0 or entity >= get_capacity():
		return result
	var dense_slot: int = sparse_index[entity]
	if dense_slot == -1:
		return result
	for index in _tracked_names.size():
		var array: Variant = _tracked_arrays[index]
		result[_tracked_names[index]] = array[dense_slot]
	return result


## Записывает нулевое значение соответствующего типа в [param dense_slot]
## каждого отслеживаемого поля.
##
## Плотные слоты переиспользуются, поэтому только что присоединённый компонент
## начинает жизнь с тем, что оставил предыдущий владелец слота. Вызывайте это
## сразу после [method attach], если у хранилища есть необязательные поля,
## которые путь создания заполняет не всегда.
func clear_slot(dense_slot: int) -> void:
	for i in _tracked_arrays.size():
		var array: Variant = _tracked_arrays[i]
		array[dense_slot] = _tracked_zeros[i]


func _reserve_dense(dense_capacity: int) -> void:
	refresh_tracked_arrays()
	if _tracked_names.is_empty():
		push_error("EcsPackedStore(тип %d): не отслеживается ни одного поля — вызовите track() в _init()" % type_id)
	for i in _tracked_arrays.size():
		var array: Variant = _tracked_arrays[i]
		array.resize(dense_capacity)


## Определён (а не унаследован), чтобы EcsComponentStore автоматически распознал
## поддержку роста: любой EcsPackedStore переживает world.reserve_capacity().
## resize() сохраняет живой префикс [0, count) — это ровно то, что требует
## контракт.
func _grow_dense(_previous_capacity: int, dense_capacity: int) -> void:
	for i in _tracked_arrays.size():
		var array: Variant = _tracked_arrays[i]
		array.resize(dense_capacity)


func _relocate_dense(from_slot: int, to_slot: int) -> void:
	for i in _tracked_arrays.size():
		var array: Variant = _tracked_arrays[i]
		array[to_slot] = array[from_slot]


## Пакетный перенос. Разрешить каждое поле один раз и затем пройти по
## перемещениям — значит превратить поиск массива «на каждое перемещение» в
## поиск «на каждое поле»; именно отсюда пакетный путь уничтожения берёт
## большую часть своей скорости.
func _relocate_dense_batch(from_slots: PackedInt32Array, to_slots: PackedInt32Array, move_count: int) -> void:
	for i in _tracked_arrays.size():
		var array: Variant = _tracked_arrays[i]
		for move in move_count:
			array[to_slots[move]] = array[from_slots[move]]


func _zero_for(value_type: int) -> Variant:
	match value_type:
		TYPE_PACKED_BYTE_ARRAY, TYPE_PACKED_INT32_ARRAY, TYPE_PACKED_INT64_ARRAY:
			return 0
		TYPE_PACKED_FLOAT32_ARRAY, TYPE_PACKED_FLOAT64_ARRAY:
			return 0.0
		TYPE_PACKED_VECTOR2_ARRAY:
			return Vector2.ZERO
		TYPE_PACKED_VECTOR3_ARRAY:
			return Vector3.ZERO
		TYPE_PACKED_VECTOR4_ARRAY:
			return Vector4.ZERO
		TYPE_PACKED_COLOR_ARRAY:
			return Color(0.0, 0.0, 0.0, 0.0)
		TYPE_PACKED_STRING_ARRAY:
			return ""
		TYPE_ARRAY:
			return null
	return null
