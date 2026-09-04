[← Common mistakes](10-common-mistakes.md) | [Contents](README.md) | [API reference →](12-api-reference.md)

---

# 11. Full example: a colony in a Petri dish

This chapter dissects a **working** example that lives in the repository:

```bash
godot --headless --script res://addons/aegis_ecs/example/colony_example.gd
```

Cells wander, spend energy, push each other apart, divide when well-fed and die
when starving. The example is deliberately assembled to exercise **everything** a
real simulation needs:

| What is used | Why it is here |
|---|---|
| `EcsPackedStore` | payload with no boilerplate |
| `EcsTagStore` | a "ready to divide" trait with no data |
| `UniformSpatialGrid` | "who is nearby", in flat 2D mode |
| `SimulationClock` | speeding time up without desync |
| the change log | reacting to birth and death |
| `EcsCapacityPolicySystem` | the population can double in seconds |
| `EcsReaperSystem` | the single point of destruction |
| phases | simulation sub-steps vs once-per-frame work |

Typical output:

```
grid: cell_size=6.00, cells=441, flat=true
seeded 200 cells

frame  population  births  deaths  capacity
    0         200     200       0       512
   60         584     584       0      1024
  120        1210    1210       0      2048
  180        1416    1418       2      2048
  240        1401    1474      73      2048
  300        1332    1533     201      2048

--- result ---
simulated 48.0 s of colony time in 360 rendered frames (time_scale 8)
population 1322, peak 1440, births 1600, deaths 278
capacity grew 2 times, now 2048
dropped substeps: 0
```

You can see the full life cycle of a colony: **growth → capacity grows twice →
saturation with mortality → stabilization**. Not a single dropped sub-step.

---

## 11.1. Components

```gdscript
class ColonyCellStore extends EcsPackedStore:
    var position: PackedVector3Array = PackedVector3Array()
    var heading: PackedFloat32Array = PackedFloat32Array()
    var energy: PackedFloat32Array = PackedFloat32Array()
    var age: PackedFloat32Array = PackedFloat32Array()
    var crowding: PackedFloat32Array = PackedFloat32Array()

    func _init() -> void:
        track(&"position", &"heading", &"energy", &"age", &"crowding")
```

**Why everything is in one store.** These five fields are read **together**, every
step, by the same systems. Splitting them across five stores would mean adding
four `sparse_index` lookups to the hottest loop — and gaining nothing
([section 4.8](04-components-and-stores.md#48-how-to-split-data-across-stores)).

**Why `crowding` is a field, not an on-the-spot computation.** A spatial query is
expensive. The movement system already asks the grid about neighbours, so it
writes the count down, and the metabolism system just reads a number. **The
expensive operation is paid for exactly once.** This is a typical and very
profitable technique in ECS: one system prepares data for another through a
component.

```gdscript
var dividing := EcsTagStore.new()
```

**Why a tag and not a `bool` in the store.** The tag gives the division system a
**dense list of exactly those cells that are ready**. With a `bool` field it
would have to scan all 1400 cells to find the dozen that are ready.

---

## 11.2. System order — and why it is exactly this

```gdscript
scheduler.add_system(ColonyMovementSystem.new(),      PHASE_SIMULATION)
scheduler.add_system(ColonySpatialIndexSystem.new(),  PHASE_SIMULATION)
scheduler.add_system(ColonyMetabolismSystem.new(),    PHASE_SIMULATION)
scheduler.add_system(ColonyDivisionSystem.new(),      PHASE_SIMULATION)
scheduler.add_system(EcsReaperSystem.new(world),      PHASE_SIMULATION)
scheduler.add_system(policy,                          PHASE_SIMULATION)
scheduler.add_system(ColonyStatisticsSystem.new(),    PHASE_STATISTICS)
```

The example's inner classes are prefixed with `Colony` (`ColonyMovementSystem`
and so on): Godot forbids an inner class from having the same name as a global
`class_name` in the project, and `Context` / `MovementSystem` /
`SpatialIndexSystem` are usually taken in a real game.

Read this list as an algorithm — that is what it is:

1. **Movement** — everyone moved and learned their own crowding.
2. **SpatialIndex** — the index is rebuilt from **the new** positions. If it stood
   before movement, every query in the next step would work from stale data.
3. **Metabolism** — energy spending depends on the crowding just measured by
   step 1. Marks the starving for destruction, the well-fed with a tag.
4. **Division** — divides the marked ones.
5. **Reaper** — the **single point of destruction**, and it is last among those
   that touch the world's membership.
6. **CapacityPolicy** — right after the reaper, because growth reallocates all
   buffers and requires that nobody is holding a dense slot.
7. **Statistics** — after the reaper, so it sees both the births and the deaths
   of this step.

---

## 11.3. The spatial query inside the movement loop

```gdscript
var neighbours: int = grid.query_sphere(point, CROWD_RADIUS, MAX_NEIGHBOURS)
crowding[slot] = float(maxi(neighbours - 1, 0))
if neighbours > 1:
    var away := Vector3.ZERO
    for i in neighbours:
        if grid.query_buffer[i] == owners[slot]:
            continue                              # that's me
        away += point - grid.query_point_buffer[i]
    if away.length_squared() > 0.0001:
        angle = AngleMath.approach(angle, atan2(away.x, away.z), 4.0 * delta)
```

Three things worth noticing:

- **`store_query_points = true`** is enabled once when the grid is configured, and
  then `query_point_buffer` hands back positions along with the identifiers.
  Without it you would have to go into the store via `index_of()` for each
  neighbour.
- **You must filter yourself out explicitly** — the grid does not know who is
  asking.
- **`MAX_NEIGHBOURS = 16`** bounds the work in the densest spots. A cell in a
  crush does not need every neighbour to figure out which way to push off.

---

## 11.4. Division: creating entities in the middle of a frame

```gdscript
var parents: int = mini(dividing.count, _context.spawn_buffer.size())
var born: int = world.create_entities(parents, _context.spawn_buffer)
if born <= 0:
    return
var first_slot: int = cells.count
cells.attach_many(_context.spawn_buffer, born)

var ready: PackedInt32Array = dividing.dense_entities
for i in born:
    var parent: int = ready[i]
    var parent_slot: int = cells.index_of(parent)
    if parent_slot == -1:
        continue
    var child_slot: int = first_slot + i
    ...
```

> **Why creating entities mid-frame is safe, but destroying them is not.**
>
> `attach()` only **appends** to the end of the dense array. It relocates
> nothing, so no slot already obtained goes bad, and the loop does not lose its
> place.
>
> `detach()`, on the contrary, does a **swap-remove** — it moves the last element
> into the freed slot. That is why destruction is deferred but creation is not.

The child cells' slots are contiguous from `first_slot`, taken **before**
`attach_many()`. That is the contract that makes batched spawning convenient.

```gdscript
dividing.clear()
```

`clear()` empties the tag **with no allocation** — it simply fills `sparse_index`
with -1 and zeroes `count`. This is much cheaper than `detach()` per cell.

---

## 11.5. Fixed step

```gdscript
var clock := SimulationClock.new()
clock.fixed_step = 1.0 / 30.0
clock.time_scale = 8.0
clock.max_substeps = 12
```

```gdscript
for frame in 360:
    var frame_delta: float = 1.0 / 60.0
    var substeps: int = clock.advance(frame_delta)

    scheduler.begin_frame()
    for step in substeps:
        scheduler.execute_phase(PHASE_SIMULATION, clock.fixed_step)
    scheduler.execute_phase(PHASE_STATISTICS, frame_delta)
```

At `time_scale = 8` and a 1/60 frame, 8/60 s accumulates, that is **four** steps
of 1/30. The simulation runs four times, the statistics once.

Without a fixed step the simulation step would be 8/60 ≈ 0.133 s, and a cell with
a division threshold of `age >= 1.0` would skip over it unevenly, depending on
the frame rate. With a fixed step the result is **reproducible**: the same seed
sequence gives the same colony on any machine.

`dropped substeps: 0` in the output confirms that the safety valve never fired —
the machine keeps up.

---

## 11.6. The change log instead of events

```gdscript
context.cells.track_changes = true
```

```gdscript
class ColonyStatisticsSystem extends EcsSystem:
    func execute(_delta: float) -> void:
        var cells: ColonyCellStore = _context.cells
        _context.births += cells.added_count
        _context.deaths += cells.removed_count
        _context.peak_population = maxi(_context.peak_population,
            _context.world.get_live_count())
        _context.world.clear_change_logs()
```

The system sits **after the reaper**, so at that moment `added_entities` holds
everything born this step and `removed_entities` holds everything that died.
Having read the log, it clears it.

In a real game this is where a death sound, particles and a UI update would fire.

---

## 11.7. Capacity growth

```gdscript
policy.on_capacity_grown = func(_previous: int, next: int) -> void:
    context.resize_scratch(next)
    context.grid.configure(DISH_RADIUS, 0.0, cell_size, next)
```

This is the single most important line of the whole example from the standpoint
of common mistakes.

**The library grows only its own buffers.** Everything the game allocated
alongside — scratch arrays for the index, the grid itself, `MultiMesh`, network
buffers — you have to grow yourself. Forgetting this means that after the world
grows, the index is built only from the first N cells, and the rest become
invisible to neighbour search. There will be no error.

In the output you can see the callback fired twice: 512 → 1024 → 2048.

---

## 11.8. What the profile shows

```
  Movement          13743      ← 82% of the frame
  SpatialIndex       1417
  Metabolism          612
  Division             10
  Reaper               11
  CapacityPolicy        1
  Statistics            3
```

Movement eats the majority. This is expected: it does a **spatial query per cell
per sub-step** — 1300 cells × 4 steps ≈ 5200 queries per frame.

If this needed optimizing, the order of actions would be
([section 9.4](09-performance.md#94-how-to-optimize-correctly)):

1. **Do not do the work.** Update crowding not every step but once every 4 steps
   — cells do not move far enough.
2. **Parameters.** Reduce `MAX_NEIGHBOURS` from 16 to 6.
3. **Fewer entities.** Query only for cells close to the division threshold.
4. **And only then** — micro-optimizing the loop itself.

The profiler here does not advise optimizing `Division` or `Metabolism`, no
matter how complex they look in the code. That is the point: **measure, do not
guess**.

---

## 11.9. Things to try on your own

The example is handy as a sandbox. A few exercises:

1. **Predators.** Add a second cell type and a `PredatorTag`. A predator finds
   the nearest prey via `grid.query_nearest()`, chases it and eats it
   (`queue_destroy` + its own energy). Where in the system list do you put the
   hunt?
2. **Food patches.** Replace the constant `FOOD_PER_SECOND` with a second spatial
   grid of nutrient patches. What `cell_size` does it need if there are 30
   patches and 1300 cells? (Hint:
   [section 8.4](08-spatial-search.md#84-the-one-that-matters-most-choosing-cell_size).)
3. **Mutations.** Add a `division_threshold` field and give a child cell the
   parent's value ± a little noise. Come back after a few minutes and see which
   value won.
4. **Speed-up.** Set `time_scale = 100`. What does `dropped_substeps` show? What
   changes if you raise `max_substeps` to 40?
5. **Pause.** Add a render system with `requires_time = false` and check that it
   runs while paused but the simulation stands still.

---

## Chapter summary

1. Keep together what is read together; pay for an expensive query once and store
   the result in a component.
2. A tag gives a dense list of candidates — cheaper than a flag in a store.
3. **Creating** entities mid-frame is safe (append); **destroying** them is not
   (swap-remove).
4. A fixed step makes the simulation reproducible at any speed-up.
5. On capacity growth, **your own buffers are your responsibility**.
6. The profiler tells you what to optimize. Intuition does not.

---

[← Common mistakes](10-common-mistakes.md) | [Contents](README.md) | [API reference →](12-api-reference.md)
