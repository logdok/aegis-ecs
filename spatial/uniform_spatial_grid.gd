class_name UniformSpatialGrid
extends RefCounted

## A uniform 3D broadphase grid built on counting sort over Packed arrays.
##
## "Broadphase" answers the question "which objects are near point X" without
## iterating every object (a full scan is O(n) per query and O(n²) in total if
## there are n queries too; unacceptable already at a couple of thousand
## objects, let alone tens of thousands). Space is cut into equal cells: an
## object lands in a cell by its coordinates, and "who is nearby" comes down to
## looking at a handful of neighbouring cells instead of the whole world.
##
## The grid is built for the "everything moves every frame" scenario: there is no
## single-object move; the index is rebuilt entirely by [method rebuild]. When
## almost everything has moved, that is cheaper than n individual updates.
##
## [b]WHY COUNTING SORT AND NOT A Dictionary "cell -> list"[/b]: a Dictionary in
## GDScript is a general-purpose hash table with per-insert overhead and, worse,
## allocations when it grows. Rebuilding one every frame does not fit the budget.
## Counting sort instead reshuffles all entries in THREE linear passes with no
## allocation at all (every buffer is pre-allocated in [method configure]), and
## all three work on THE SAME `_cell_offsets` array — there is no separate cursor
## array:
##   Pass 1: compute each entry's cell and increment its counter (a histogram).
##   Pass 2: turn the histogram into INCLUSIVE prefix sums in place, so that
##           _cell_offsets[c] becomes the index JUST PAST cell c's last entry.
##   Pass 3: scatter the entries into their final slots, walking FROM END TO
##           START and decrementing _cell_offsets[cell] before each write. The
##           side effect is exactly what is needed next: by the end of the pass
##           every _cell_offsets[c] has been decremented by exactly its cell's
##           size and points at the cell's START again.
## The result is an array sorted by cell: everything in one cell is contiguous,
## and not a single malloc over the whole rebuild.
##
## WHY PASS 3 GOES BACKWARDS: it is the classic counting-sort trick that lets one
## array do the work of two (the histogram plus the write cursor). The saving is
## not only memory (40 KB on a 10,000-cell grid) but also speed: the hot loop
## touches one array instead of two, that is half as many cache lines. The sort
## also stays STABLE.
##
## [b]THE REBUILD COST IS O(entries + CELLS)[/b], not just O(entries): passes 1
## and 3 are linear in the number of entries, but pass 2 must walk EVERY cell,
## empty ones included. That is exactly why [param cell_size] matters so much: a
## grid of 10,000 cells with 30 objects living in it spends almost all its time
## on emptiness. Keep [method get_cell_count] comparable to the expected number
## of objects, or call [method suggest_cell_size] and let it do the arithmetic.
##
## [b]FLAT (2D) MODE[/b]: pass `vertical_extent = 0.0` and the grid collapses
## into a single layer, cutting the cell count — and with it the constant part of
## every rebuild — by as many times as there would otherwise be vertical layers.
## For a top-down game, an RTS, bullet hell or anything on a plane, that is a
## free speed-up; see [method configure].
##
## THE CELL INDEX LAYOUT is chosen so that the whole X range of one row is
## CONTIGUOUS in the sorted array (cell = (cy*dim_z + cz)*dim_x + cx). So a
## sphere query reads one flat strip per row instead of poking at each cell
## individually — fewer cache misses and fewer array accesses.

## An upper bound on how many ids one query_sphere() call can return.
const MAX_QUERY_RESULTS: int = 2048

var _cell_size: float = 1.0
var _inv_cell_size: float = 1.0
var _dim_x: int = 0
var _dim_y: int = 0
var _dim_z: int = 0
var _cell_count: int = 0
var _origin_xz: float = 0.0
var _flat: bool = false

## Its size is _cell_count + 1. Over the course of [method rebuild] the array
## plays three roles in turn: histogram -> cell "ends" -> cell "starts". By the
## time rebuild returns it is always "starts": _cell_offsets[c] is the index of
## cell c's first entry, and _cell_offsets[c + 1] the index just past its last.
var _cell_offsets: PackedInt32Array = PackedInt32Array()

var _scratch_cells: PackedInt32Array = PackedInt32Array()
var _entry_count: int = 0

## Entries sorted by cell. Read-only from outside — the same as [EcsComponentStore]'s
## public fields: exposed so a system can write its own traversal (all pairs
## within a cell, a non-standard region shape, k nearest) without extra copying.
## The valid prefix is [0, get_entry_count()).
var sorted_entities: PackedInt32Array = PackedInt32Array()
var sorted_points: PackedVector3Array = PackedVector3Array()

## The result of the last [method query_sphere]. Read-only from outside and
## OVERWRITTEN by the next query.
var query_buffer: PackedInt32Array = PackedInt32Array()

## The positions matching [member query_buffer]; filled only while
## [member store_query_points] is true.
var query_point_buffer: PackedVector3Array = PackedVector3Array()

## Makes [method query_sphere] also fill [member query_point_buffer]. Off by
## default so that callers who only need ids do not pay for the extra write;
## enabled, it saves the caller a sparse lookup plus an array read per hit, which
## is the typical shape of a flocking or push-apart loop.
var store_query_points: bool = false


## [param arena_radius] sets the bound on the XZ plane (the arena is a square or
## circle around the origin), [param vertical_extent] the bound on Y upward from
## zero. Anything outside these bounds is not lost and does not raise an error —
## it is clamped into the edge cells, so queries near the arena boundary stay
## correct.
##
## [b]For a flat world, pass `vertical_extent = 0.0`[/b] and the grid uses a
## single Y layer. The Y coordinate is then ignored when bucketing into cells
## (distance checks stay fully three-dimensional) — which is exactly what a game
## on a plane needs, and it removes the vertical multiplier from the cell count.
##
## [param entry_capacity] is the largest number of entries a single
## [method rebuild] will ever receive; the buffers are sized for it once here.
func configure(arena_radius: float, vertical_extent: float, cell_size: float, entry_capacity: int) -> void:
	_cell_size = maxf(cell_size, 0.01)
	_inv_cell_size = 1.0 / _cell_size
	_origin_xz = -arena_radius
	_dim_x = int(ceil(arena_radius * 2.0 * _inv_cell_size)) + 1
	_dim_z = _dim_x
	_flat = vertical_extent <= 0.0
	_dim_y = 1 if _flat else int(ceil(maxf(vertical_extent, _cell_size) * _inv_cell_size)) + 1
	_cell_count = _dim_x * _dim_y * _dim_z

	_cell_offsets.resize(_cell_count + 1)
	_scratch_cells.resize(entry_capacity)
	sorted_entities.resize(entry_capacity)
	sorted_points.resize(entry_capacity)
	query_buffer.resize(mini(entry_capacity, MAX_QUERY_RESULTS))
	query_point_buffer.resize(query_buffer.size())
	_entry_count = 0


## Suggests a [param cell_size] for [method configure].
##
## Two forces pull in opposite directions: small cells make the rebuild
## expensive (pass 2 walks every cell) but queries cheap; large cells make the
## rebuild almost free but queries expensive (more distant candidates to
## distance-check). The equilibrium is roughly "one cell per expected object",
## with a lower bound of about twice the typical query radius so a query still
## reads only a few cells.
##
## For a flat grid, pass `vertical_extent = 0.0`, as in [method configure]. The
## result is a starting point, not a law: profile and adjust.
static func suggest_cell_size(
	arena_radius: float,
	vertical_extent: float,
	expected_entries: int,
	typical_query_radius: float,
) -> float:
	var span: float = maxf(arena_radius * 2.0, 0.01)
	var entries: float = float(maxi(expected_entries, 1))
	var density_size: float
	if vertical_extent <= 0.0:
		# (span / c)^2 == entries
		density_size = span / sqrt(entries)
	else:
		# (span / c)^2 * (vertical_extent / c) == entries
		density_size = pow(span * span * maxf(vertical_extent, 0.01) / entries, 1.0 / 3.0)
	return maxf(density_size, maxf(typical_query_radius, 0.01) * 2.0)


## Fully rebuilds the index from a flat pair of "entity id, point" arrays. Both
## must hold at least [param entry_count] valid elements — this lets the calling
## system keep reusable buffers with spare room and pass only the filled part,
## trimming nothing.
func rebuild(entity_ids: PackedInt32Array, points: PackedVector3Array, entry_count: int) -> void:
	# Guard against overflowing the pre-allocated buffers: the grid physically
	# cannot take more entries than configure() was told about. Silently taking
	# the first entry_capacity is better than going out of bounds.
	entry_count = clampi(entry_count, 0, _scratch_cells.size())
	_entry_count = entry_count
	_cell_offsets.fill(0)
	if entry_count <= 0:
		# All offsets are zero, so any strip [start, end) is empty and queries
		# correctly find nothing even without an early return.
		return

	var last_x: int = _dim_x - 1
	var last_z: int = _dim_z - 1
	var cells: PackedInt32Array = _scratch_cells
	var offsets: PackedInt32Array = _cell_offsets
	var origin: float = _origin_xz
	var inv: float = _inv_cell_size
	var dim_x: int = _dim_x
	var dim_z: int = _dim_z

	# Pass 1 -- determine each entry's cell and build a histogram in _cell_offsets.
	if _flat:
		for i in entry_count:
			var p: Vector3 = points[i]
			var cx: int = clampi(int((p.x - origin) * inv), 0, last_x)
			var cz: int = clampi(int((p.z - origin) * inv), 0, last_z)
			var cell: int = cz * dim_x + cx
			cells[i] = cell
			offsets[cell] += 1
	else:
		var last_y: int = _dim_y - 1
		for i in entry_count:
			var p: Vector3 = points[i]
			var cx: int = clampi(int((p.x - origin) * inv), 0, last_x)
			var cy: int = clampi(int(p.y * inv), 0, last_y)
			var cz: int = clampi(int((p.z - origin) * inv), 0, last_z)
			var cell: int = (cy * dim_z + cz) * dim_x + cx
			cells[i] = cell
			offsets[cell] += 1

	# Pass 2 -- turn the histogram into INCLUSIVE prefix sums in place, so that
	# _cell_offsets[c] is the index just past cell c's last entry. The last
	# element (index _cell_count) is the total entry count: it serves as the
	# "end" of the last cell and is not changed in pass 3, since no entry
	# addresses that cell.
	var running: int = 0
	for c in _cell_count:
		running += offsets[c]
		offsets[c] = running
	offsets[_cell_count] = running

	# Pass 3 -- scatter the entries, walking FROM END TO START and decrementing
	# each cell's "end" before each write. After the pass every _cell_offsets[c]
	# has been decremented by exactly its cell's size, that is, points at its
	# start again -- no separate cursor array needed.
	var out_entities: PackedInt32Array = sorted_entities
	var out_points: PackedVector3Array = sorted_points
	var i: int = entry_count
	while i > 0:
		i -= 1
		var cell: int = cells[i]
		var slot: int = offsets[cell] - 1
		offsets[cell] = slot
		out_entities[slot] = entity_ids[i]
		out_points[slot] = points[i]


## Returns the id of the nearest indexed entity within [param radius], or -1.
## Allocates nothing — that is what makes a wide search radius safe: widening it
## costs CPU time but never memory.
##
## Like query_sphere below, it first computes a cell-bounding box around the
## sphere and walks only the cells inside it, not the whole grid.
func query_nearest(center: Vector3, radius: float) -> int:
	if _entry_count <= 0:
		return -1
	var best_entity: int = -1
	var best_distance_sq: float = radius * radius

	var min_x: int = clampi(int((center.x - radius - _origin_xz) * _inv_cell_size), 0, _dim_x - 1)
	var max_x: int = clampi(int((center.x + radius - _origin_xz) * _inv_cell_size), 0, _dim_x - 1)
	var min_y: int = clampi(int((center.y - radius) * _inv_cell_size), 0, _dim_y - 1)
	var max_y: int = clampi(int((center.y + radius) * _inv_cell_size), 0, _dim_y - 1)
	var min_z: int = clampi(int((center.z - radius - _origin_xz) * _inv_cell_size), 0, _dim_z - 1)
	var max_z: int = clampi(int((center.z + radius - _origin_xz) * _inv_cell_size), 0, _dim_z - 1)

	var offsets: PackedInt32Array = _cell_offsets
	var points: PackedVector3Array = sorted_points
	var entities: PackedInt32Array = sorted_entities

	for cy in range(min_y, max_y + 1):
		for cz in range(min_z, max_z + 1):
			# Thanks to the (cy*dim_z + cz)*dim_x + cx layout, the whole X range
			# of one row is contiguous, so this reads one flat strip
			# [start, end) rather than dim_x separate cells.
			var row_base: int = (cy * _dim_z + cz) * _dim_x
			var slice_start: int = offsets[row_base + min_x]
			var slice_end: int = offsets[row_base + max_x + 1]
			for s in range(slice_start, slice_end):
				var distance_sq: float = points[s].distance_squared_to(center)
				if distance_sq < best_distance_sq:
					best_distance_sq = distance_sq
					best_entity = entities[s]
	return best_entity


## Fills [member query_buffer] with every indexed entity within [param radius]
## and returns how many ids were written (no more than [param result_limit] and
## no more than the buffer's own size).
##
## [b]The result deliberately goes into a field, not an out parameter.[/b] That
## makes the ownership and lifetime of the result obvious, and returning a new
## array would allocate on every query. The internal buffer is reused, so a
## steady-state query allocates nothing.
##
## Set [member store_query_points] to also get the matching positions in
## [member query_point_buffer].
##
## [b]Note:[/b] both buffers are overwritten by the next query. Read them before
## the next query, or copy what you need.
##
## When the limit is reached the scan stops, so a truncated result is biased
## toward the lower corner of the search region rather than being a random
## sample.
func query_sphere(center: Vector3, radius: float, result_limit: int) -> int:
	if _entry_count <= 0:
		return 0
	var capped_limit: int = mini(result_limit, query_buffer.size())
	if capped_limit <= 0:
		return 0
	var written: int = 0
	var radius_sq: float = radius * radius

	var min_x: int = clampi(int((center.x - radius - _origin_xz) * _inv_cell_size), 0, _dim_x - 1)
	var max_x: int = clampi(int((center.x + radius - _origin_xz) * _inv_cell_size), 0, _dim_x - 1)
	var min_y: int = clampi(int((center.y - radius) * _inv_cell_size), 0, _dim_y - 1)
	var max_y: int = clampi(int((center.y + radius) * _inv_cell_size), 0, _dim_y - 1)
	var min_z: int = clampi(int((center.z - radius - _origin_xz) * _inv_cell_size), 0, _dim_z - 1)
	var max_z: int = clampi(int((center.z + radius - _origin_xz) * _inv_cell_size), 0, _dim_z - 1)

	var offsets: PackedInt32Array = _cell_offsets
	var points: PackedVector3Array = sorted_points
	var entities: PackedInt32Array = sorted_entities
	var out_ids: PackedInt32Array = query_buffer
	var out_points: PackedVector3Array = query_point_buffer
	var with_points: bool = store_query_points

	for cy in range(min_y, max_y + 1):
		for cz in range(min_z, max_z + 1):
			var row_base: int = (cy * _dim_z + cz) * _dim_x
			var slice_start: int = offsets[row_base + min_x]
			var slice_end: int = offsets[row_base + max_x + 1]
			for s in range(slice_start, slice_end):
				# The cell range is only the sphere's bounding box, not the
				# sphere itself, so every point in the strip is still checked by
				# exact distance: otherwise corner points farther than radius
				# would end up in the result.
				var point: Vector3 = points[s]
				if point.distance_squared_to(center) > radius_sq:
					continue
				if written >= capped_limit:
					return written
				out_ids[written] = entities[s]
				if with_points:
					out_points[written] = point
				written += 1
	return written


## The index of the cell containing [param point], or -1 if the grid is not
## configured. Together with [method get_cell_start] / [method get_cell_end] it
## lets you write your own traversal over [member sorted_entities] and
## [member sorted_points].
func get_cell_index(point: Vector3) -> int:
	if _cell_count <= 0:
		return -1
	var cx: int = clampi(int((point.x - _origin_xz) * _inv_cell_size), 0, _dim_x - 1)
	var cz: int = clampi(int((point.z - _origin_xz) * _inv_cell_size), 0, _dim_z - 1)
	if _flat:
		return cz * _dim_x + cx
	var cy: int = clampi(int(point.y * _inv_cell_size), 0, _dim_y - 1)
	return (cy * _dim_z + cz) * _dim_x + cx


## The first index of cell [param cell] in the sorted arrays.
func get_cell_start(cell: int) -> int:
	return _cell_offsets[cell]


## The index just past the last element of cell [param cell].
func get_cell_end(cell: int) -> int:
	return _cell_offsets[cell + 1]


func get_entry_count() -> int:
	return _entry_count


func get_cell_count() -> int:
	return _cell_count


func get_cell_size() -> float:
	return _cell_size


## The number of cells per axis, as (x, y, z). In flat mode y is 1.
func get_dimensions() -> Vector3i:
	return Vector3i(_dim_x, _dim_y, _dim_z)


func is_flat() -> bool:
	return _flat
