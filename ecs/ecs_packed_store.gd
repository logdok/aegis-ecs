class_name EcsPackedStore
extends EcsComponentStore

## A declarative component store: you declare the data fields, and the base class
## writes all the wiring.
##
## [EcsComponentStore] requires you to hand-write [method _reserve_dense] and
## [method _relocate_dense] for every store, and a forgotten second method
## silently corrupts data on every removal. This subclass removes a whole class
## of bugs: name your fields once, and all memory allocation, capacity growth and
## swap-remove relocation are done for you.
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
## [b]In the hot loop this costs nothing.[/b] The fields stay ordinary typed
## class members, so a system reads them directly and at full speed:
## [codeblock]
## var px: PackedFloat32Array = positions.x
## for dense in positions.count:
##     px[dense] += 1.0
## [/codeblock]
## The generic work happens only during allocation and removal, and even there
## the base class resolves each field once for the whole operation and then walks
## the moves — measurably faster than the virtual call per move that a
## hand-written store pays.
##
## [b]Supported field types[/b]: any `Packed*Array`, and also a plain `Array` for
## data with objects or resources. An `Array` field that OWNS what it references
## must additionally define [code]_release_dense()[/code] (see
## [EcsComponentStore]).
##
## [b]If you ever assign a whole new array to a tracked field[/b]
## (`x = PackedFloat32Array()`) rather than modifying it in place — call
## [method refresh_tracked_arrays] afterwards so the cached references point at
## the new arrays.

var _tracked_names: Array[StringName] = []
var _tracked_arrays: Array = []
var _tracked_zeros: Array = []


## Registers the data fields by name. Call it once from `_init()`. It accepts any
## number of names, so a store usually needs a single line.
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


## Registers one data field. Useful when there are more fields than [method track]
## accepts, or when the names are computed.
func track_field(field_name: StringName) -> void:
	if _tracked_names.has(field_name):
		push_error("EcsPackedStore: field '%s' is registered twice" % field_name)
		return
	var value: Variant = get(field_name)
	if value == null:
		push_error("EcsPackedStore: this store has no field named '%s'" % field_name)
		return
	var zero: Variant = _zero_for(typeof(value))
	if zero == null and typeof(value) != TYPE_ARRAY:
		push_error("EcsPackedStore: field '%s' has type %s, which is neither a Packed*Array nor an Array"
			% [field_name, type_string(typeof(value))])
		return
	_tracked_names.append(field_name)
	_tracked_arrays.append(value)
	_tracked_zeros.append(zero)


## Re-resolves the cached array references from the live fields. Needed only in
## the rare case where a tracked field was assigned a whole new array rather than
## modified in place.
func refresh_tracked_arrays() -> void:
	for i in _tracked_names.size():
		_tracked_arrays[i] = get(_tracked_names[i])


## The number of registered data fields. Useful in tests and tooling.
func get_tracked_field_count() -> int:
	return _tracked_names.size()


func get_tracked_field_name(index: int) -> StringName:
	return _tracked_names[index]


## Generically reads one data value — for the debug interface and tooling.
##
## This is what lets the inspector show a whole component while knowing nothing
## about the store: the field names are already registered, and the values are
## fetched here. Read-only, deliberately: there is no generic setter, because
## writing into a live simulation from a debug panel is a separate decision with
## different safety rules.
##
## Cold path: it goes through a Variant-typed container. Never call it from a
## system.
func get_field_value(field_index: int, dense_slot: int) -> Variant:
	if field_index < 0 or field_index >= _tracked_arrays.size():
		return null
	if dense_slot < 0 or dense_slot >= count:
		return null
	var array: Variant = _tracked_arrays[field_index]
	return array[dense_slot]


## A convenience for tooling: all tracked fields of one entity as
## `{ field_name: value }`, or an empty dictionary if the entity has no
## component.
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


## Writes the type-appropriate zero value into [param dense_slot] of every
## tracked field.
##
## Dense slots are reused, so a just-attached component starts life with whatever
## the previous owner of the slot left behind. Call this right after
## [method attach] if the store has optional fields that the creation path does
## not always fill.
func clear_slot(dense_slot: int) -> void:
	for i in _tracked_arrays.size():
		var array: Variant = _tracked_arrays[i]
		array[dense_slot] = _tracked_zeros[i]


func _reserve_dense(dense_capacity: int) -> void:
	refresh_tracked_arrays()
	if _tracked_names.is_empty():
		push_error("EcsPackedStore(type %d): no field is tracked — call track() in _init()" % type_id)
	for i in _tracked_arrays.size():
		var array: Variant = _tracked_arrays[i]
		array.resize(dense_capacity)


## Defined (not inherited) so that EcsComponentStore auto-detects growth support:
## any EcsPackedStore survives world.reserve_capacity(). resize() keeps the live
## prefix [0, count) — which is exactly what the contract requires.
func _grow_dense(_previous_capacity: int, dense_capacity: int) -> void:
	for i in _tracked_arrays.size():
		var array: Variant = _tracked_arrays[i]
		array.resize(dense_capacity)


func _relocate_dense(from_slot: int, to_slot: int) -> void:
	for i in _tracked_arrays.size():
		var array: Variant = _tracked_arrays[i]
		array[to_slot] = array[from_slot]


## Batched relocation. Resolving each field once and then walking the moves turns
## the array lookup from "per move" into "per field"; that is where the batched
## destruction path gets most of its speed.
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
