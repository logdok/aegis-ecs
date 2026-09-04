[← Time and events](07-time-events-capacity.md) | [Contents](README.md) | [Performance →](09-performance.md)

---

# 8. Spatial search

---

## 8.1. The problem

"Which objects are near point X right now?"

The naive answer is to iterate everyone and compare distances. That is `O(n)` per
query. If there are also `n` queries (every enemy looking for its nearest
neighbour), it becomes `O(n²)`: for 10,000 objects that is 100 million checks per
frame. Unacceptable already at a few thousand.

`UniformSpatialGrid` solves this by dividing space into equal cells. An object
lands in a cell by its coordinates, and the "who is nearby" search comes down to
looking at a handful of neighbouring cells instead of the whole world.

---

## 8.2. Basic usage

```gdscript
var grid := UniformSpatialGrid.new()

# Once, at assembly:
grid.configure(
    130.0,      # arena_radius: the XZ-plane boundary
    0.0,        # vertical_extent: 0 = flat (2D) mode
    10.0,       # cell_size
    10000,      # entry_capacity: maximum entries per rebuild
)
```

Every frame, **after** everyone has moved:

```gdscript
grid.rebuild(entity_ids, points, entry_count)
```

Then — queries:

```gdscript
# The nearest one within a radius, or -1.
var nearest: int = grid.query_nearest(center, 12.0)

# Everyone within a radius. Returns the count; the ids are in query_buffer.
var found: int = grid.query_sphere(center, 10.0, 64)
for i in found:
    var entity: int = grid.query_buffer[i]
```

> **`query_buffer` is overwritten by the next query.** Read it immediately or
> copy what you need. The result deliberately goes into a class field rather than
> an out parameter: this makes the ownership and lifetime of the result obvious,
> and returning a new array would allocate memory on every query.

### Rebuild, not move

The grid is built for the "everything moves every frame" scenario: it **does
not** support moving a single object; it rebuilds entirely. For a simulation
where almost everything moved, this is cheaper than `n` individual updates.

---

## 8.3. Flat (2D) mode

```gdscript
grid.configure(130.0, 0.0, 10.0, 10000)     # vertical_extent = 0
```

If your game happens on a plane — top-down, RTS, bullet hell, a Petri-dish
simulation — pass `vertical_extent = 0.0` and the grid collapses into a single
layer.

The Y coordinate is then ignored when bucketing into cells (distance checks
remain fully three-dimensional), and the cell count drops by as many times as
there would otherwise be vertical layers.

In measurements on the same data: rebuilding 10,000 entries is **3.06 ms in 3D vs
2.21 ms in flat mode** (10,125 cells vs 2,025).

Check the mode: `grid.is_flat()`, `grid.get_dimensions()`.

---

## 8.4. The one that matters most: choosing cell_size

The cost of `rebuild()` is **`O(entries + CELL COUNT)`**, not just `O(entries)`.

The reason is inside the algorithm: the grid is built on a **counting sort**, and
its second pass (the prefix sums) is obliged to walk **all** cells, empty ones
included. A grid of 10,000 cells with 30 objects living in it spends almost all
its time on emptiness.

Two forces pull in opposite directions:

- **small cells** ruin the rebuild but speed up queries — there are fewer
  candidates in each cell;
- **large cells** make the rebuild almost free, but queries degrade: you have to
  check the distance to a heap of extra candidates.

Measurements on a 130 × 24 arena (`get_cell_count()` in parentheses):

| `cell_size` | cells | `rebuild` 32 entries | `rebuild` 10,000 | 512 × `query_nearest` |
|---|---|---|---|---|
| 3 | 69,696 | 2257 µs | 4.7 ms | 4.9 ms |
| 6 | 10,125 | 338 µs | 2.8 ms | 3.4 ms |
| 10 | 2,916 | 102 µs | 2.6 ms | 3.4 ms |
| 16 | 972 | 39 µs | 2.5 ms | 4.2 ms |
| 26 | 242 | 16 µs | 2.5 ms | 6.2 ms |
| 40 | 128 | 12 µs | 2.5 ms | 9.4 ms |
| 65 | 50 | 10 µs | 2.5 ms | 18.3 ms |

### The rule of thumb

Keep `get_cell_count()` **comparable to the expected number of objects**, and
`cell_size` itself **2–4× larger than the typical query radius**.

Or just ask the library:

```gdscript
var size: float = UniformSpatialGrid.suggest_cell_size(
    130.0,      # arena_radius
    0.0,        # vertical_extent (0 = flat)
    10000,      # expected number of objects
    12.0,       # typical query radius
)
grid.configure(130.0, 0.0, size, 10000)
```

The formula takes "roughly one cell per object" and raises the result to at
least twice the query radius. This is a starting point, not a law — profile from
there.

### Several grids with different `cell_size`

This is a **recommended pattern**, not a trick.

If your scene has both a dense mass of small objects and a dozen large rare ones,
a single shared grid is bad for both. Set up two:

```gdscript
# 10,000 units, small cells: the rebuild is expensive but queries are fast
units_grid.configure(130.0, 0.0, 6.0, 10000)

# 30 projectiles, large cells: iterating 10,000 empty cells for the sake of
# thirty entries would be pure waste
missiles_grid.configure(130.0, 0.0, 40.0, 64)
```

A real measurement from a game where missiles first shared a grid with enemies:
moving to a separate grid with `cell_size = 40` instead of 6 gave **350 → 17
µs**, that is minus 12% of the frame.

---

## 8.5. Positions alongside identifiers

The typical "find neighbours and compute a force" loop after `query_sphere()`
would, for each found id, still have to fetch its position through its own store.
The grid already has those positions:

```gdscript
grid.store_query_points = true          # once

var found: int = grid.query_sphere(center, 10.0, 64)
for i in found:
    var entity: int = grid.query_buffer[i]
    var point: Vector3 = grid.query_point_buffer[i]     # no extra lookup
    var push: Vector3 = (center - point).normalized()
```

Off by default, so those who only need ids do not pay for the extra write.

---

## 8.6. Custom cell iteration

For non-standard tasks — "all pairs within a cell", a non-standard region shape,
k nearest — the grid exposes its sorted arrays:

```gdscript
var cell: int = grid.get_cell_index(point)
var start: int = grid.get_cell_start(cell)
var end: int = grid.get_cell_end(cell)

for s in range(start, end):
    var entity: int = grid.sorted_entities[s]
    var position: Vector3 = grid.sorted_points[s]
```

`sorted_entities` and `sorted_points` are **read-only**, by the same convention
as the public store fields.

---

## 8.7. Geometric assumptions

- The world is centred at zero on the **X and Z** axes: range
  `[-arena_radius, +arena_radius]`.
- On **Y** the count runs upward from zero: range `[0, vertical_extent]`.
- Objects **are not lost outside these bounds** — they are clamped to the edge
  cells, so queries near the arena boundary stay correct.
- `query_sphere()` **stops searching** once it hits the limit, so a truncated
  result is biased toward the lower corner of the search region rather than being
  a random sample.

---

## 8.8. `AngleMath`

A small independent module for smooth turning.

```gdscript
# Turn current toward desired, by no more than max_step, along the shortest path.
yaw = AngleMath.approach(yaw, desired_yaw, turn_rate * delta)

# The absolute shortest angular distance — "how far", with no direction.
if AngleMath.shortest_delta(yaw, desired_yaw) < firing_tolerance:
    fire()
```

**Why this is not trivial.** The naive
`current += clamp(desired - current, -max_step, max_step)` breaks at the ±π
crossover. If `current = 3.1` and `desired = -3.1`, the "straight" difference is
−6.2 rad, even though the shortest path between those angles is only 0.08 rad
**the other way**. `wrapf(..., -PI, PI)` brings the difference to its shortest
equivalent before the step clamp.

---

## Chapter summary

1. The grid **rebuilds entirely** every frame; there is no single-object move.
2. The rebuild cost is `O(entries + CELLS)`, so `cell_size` is critical.
3. **Flat mode** (`vertical_extent = 0`) is a free speed-up for a game on a
   plane.
4. `suggest_cell_size()` gives a reasoned starting point.
5. Object sets with different populations need **different grids** with different
   `cell_size`.
6. `query_buffer` is overwritten by the next query.
7. `AngleMath.approach()` is a correct turn across ±π.

---

[← Time and events](07-time-events-capacity.md) | [Contents](README.md) | [Performance →](09-performance.md)
