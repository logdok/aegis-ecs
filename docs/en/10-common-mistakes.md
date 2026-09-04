[← Performance](09-performance.md) | [Contents](README.md) | [Full example →](11-full-example.md)

---

# 10. Common mistakes

A reference in "symptom → cause → fix" format. Most of these mistakes **produce
no messages in the console** — which is exactly why this chapter exists.

---

## 10.1. Silent bugs (the most dangerous)

### Data got mixed up after a removal

**Symptom.** Entities are alive, components are in place, but the values belong
to the wrong ones — an enemy has someone else's health, a projectile flies the
wrong way. No errors.

**Cause.** A hand-written store (`EcsComponentStore`) did not implement
`_relocate_dense()`. On swap-remove the last element moved into the removed one's
place, but its payload stayed where it was.

**Fix.**

```gdscript
func _relocate_dense(from_slot: int, to_slot: int) -> void:
    # EVERY field, no exceptions
    health[to_slot] = health[from_slot]
    armor[to_slot] = armor[from_slot]
```

**How not to step on it again.** Use `EcsPackedStore` — there this is implemented
for you, and it is impossible to forget. If the store must be hand-written, write
a dedicated test for it: create two entities with **distinguishable** values in
every field, remove the first, check the second.

---

### Data is written but not kept

**Symptom.** A system writes something, the next system does not see it.

**Cause.** Most often — indexing the data array by the **entity identifier**
instead of the dense slot.

```gdscript
# WRONG
positions.x[entity] = 5.0

# RIGHT
var slot: int = positions.index_of(entity)
if slot != -1:
    positions.x[slot] = 5.0
```

**A rarer variant:** you assigned a store field a whole new array
(`store.x = PackedFloat32Array()`), and in `EcsPackedStore` the reference cache
went stale. Call `store.refresh_tracked_arrays()` — or, better, do not assign
fields wholesale.

---

### A system reads last frame's data

**Symptom.** Collisions fire with a delay, targeting "lags" by a frame, the
neighbour index shows old positions.

**Cause.** The system is in **the wrong place** in the registration list.

```gdscript
# WRONG: the index is built from old positions
scheduler.add_system(SpatialIndexSystem.new())
scheduler.add_system(MovementSystem.new())

# RIGHT
scheduler.add_system(MovementSystem.new())
scheduler.add_system(SpatialIndexSystem.new())
```

**Registration order is behaviour.** There will be no error; there will be a
different game.

---

### Use-after-free within a frame

**Symptom.** Occasionally, "once every hundred frames", data belongs to the wrong
entity.

**Cause.** A dense slot was cached **across** a structural change.

```gdscript
# WRONG
var slot: int = positions.index_of(entity)
world.flush_destroy_queue()          # swap-remove could have moved data
positions.x[slot] = 0.0              # writing into someone else's component
```

**Fix.** Take the slot again after any structural change. And keep
`flush_destroy_queue()` at **exactly one point in the frame** — use
`EcsReaperSystem`.

> A handle cures a stale **entity reference**, but not a stale **slot**.

---

### An iteration fell apart mid-flight

**Symptom.** Some entities are skipped, counters do not add up.

**Cause.** A store's membership is changed **in the middle of iterating that same
store**.

```gdscript
# WRONG
for dense in positions.count:
    if should_die(dense):
        positions.detach(positions.dense_entities[dense])   # the array shifted
```

**Fix.** Mark, and remove later:

```gdscript
for dense in positions.count:
    if should_die(dense):
        world.queue_destroy(positions.dense_entities[dense])
```

---

## 10.2. Mistakes with a console message

### `create_entity()` returned -1

**Cause.** The world is full: `get_free_count() == 0`.

**Fix.** Either increase the initial capacity, or use
[`EcsCapacityPolicySystem`](07-time-events-capacity.md#73-capacity-and-growth-policy),
or destroy more aggressively. And **always check the result** — this is not an
exceptional situation but a normal state.

---

### `register_store()` returned `false`

Three possible causes:

| Message | Cause |
|---|---|
| `schema locked by the first create_entity()` | The store is registered **after** the first entity. Register all stores before creating. |
| `component type N already registered` | A duplicated type constant. |
| `store already registered under another type id or world` | The same store object is being inserted twice. |

---

### `reserve_capacity()` returned `false`

**Cause.** Either the request is smaller than the current capacity, or some store
has no `_grow_dense()`.

**Fix.** Add the hook to the hand-written store:

```gdscript
func _grow_dense(_previous_capacity: int, dense_capacity: int) -> void:
    values.resize(dense_capacity)
```

`EcsPackedStore` and `EcsTagStore` support growth always. Check:
`store.supports_capacity_growth()`.

---

### `_clear_relocated_dense() without _release_dense()`

**Cause.** You implemented clearing the duplicate but not freeing the thing being
removed. This almost always means a **resource leak**.

**Fix.** Implement both — see
[section 4.6](04-components-and-stores.md#46-components-that-own-resources).

---

### `one instance cannot be registered in two schedulers`

**Cause.** One `EcsSystem` object was added to two schedulers.

**Fix.** Create a separate instance for each pipeline.

---

### `system X did not declare access to type N`

**Cause.** The `view.validate_owner_access()` diagnostic: the system uses a type
through a View that it did not declare.

**Fix.** Either add `declare_read/declare_write`, or do not call the validation.
It affects execution in no way.

---

## 10.3. Performance problems

### The frame "dips" exactly when many things die

**Cause.** Destruction costs `O(victims × stores)`.

**Fix.**
- Merge small stores.
- Spread a mass death over several frames.
- For a full wipe use `world.reset()`, not a mass `queue_destroy`.

---

### The grid rebuild eats the whole frame

**Cause.** A bad `cell_size`: the cost is `O(entries + CELLS)`.

**Fix.** `UniformSpatialGrid.suggest_cell_size()`, flat mode for a game on a
plane, separate grids for sets with different populations. See
[section 8.4](08-spatial-search.md#84-the-one-that-matters-most-choosing-cell_size).

---

### `EcsQuery` rebuilds every frame

**Cause.** Some participating store changes its membership every frame — often a
tag that someone attaches and detaches each frame.

**Check:**

```gdscript
print(query.get_rebuild_count())     # growing by 1 every frame?
```

**Fix.** Either remove the volatile tag from the query's membership, or move to
`EcsView` / the direct loop — a cache that always misses only adds work.

---

### Iteration is slower than expected

**Cause.** Reading object fields in the loop instead of local aliases.

**Fix.** See [section 9.1](09-performance.md#91-the-gdscript-cost-model).

---

## 10.4. Mistakes when speeding time up

### The simulation "jumps over" events at high speed

**Symptom.** At `time_scale = 50` cells divide less often than they should;
projectiles fly through targets.

**Cause.** Raw `delta` multiplied by the scale gives a huge step.

**Fix.** [`SimulationClock`](07-time-events-capacity.md#71-simulationclock--fixed-step-and-time-scale).

---

### The game hangs when sped up

**Cause.** The "death spiral": each next frame is slower than the previous one.

**Fix.** `clock.max_substeps` (8 by default). Watch `clock.dropped_substeps` — if
it grows, the machine cannot keep up with the requested rate.

---

### Something still moves while paused

**Cause.** The system did not declare `requires_time = true`.

**Fix.**

```gdscript
func _init() -> void:
    system_name = "Movement"
    requires_time = true
```

---

### Entities pile up in the queue during a pause

**Cause.** The reaper was given `requires_time = true`.

**Fix.** Do not do that. `EcsReaperSystem` deliberately runs while paused too.

---

## 10.5. Quick diagnosis

When it is unclear what is even happening:

```gdscript
# 1. Is the world intact?
if not world.validate_integrity():
    breakpoint

# 2. What about the population?
print("live=%d free=%d pending=%d load=%.2f" % [
    world.get_live_count(), world.get_free_count(),
    world.get_pending_destroy_count(), world.get_load_factor()])

# 3. Are the stores consistent with the world?
print("positions=%d hostiles=%d" % [positions.count, hostile_tag.count])

# 4. Where does the time go?
for i in scheduler.get_system_count():
    print("%-24s %6d µs" % [scheduler.get_system_name(i),
        int(scheduler.get_average_timing_usec(i))])

# 5. Is the pipeline assembled correctly?
scheduler.validate_pipeline(world)
```

---

## Checklist before looking for a bug somewhere else

- [ ] Do hand-written stores implement `_relocate_dense()` for **every** field?
- [ ] Is `flush_destroy_queue()` called in **exactly one place**?
- [ ] Is data indexed by the **slot**, not the entity id?
- [ ] Does the system order match the data-dependency order?
- [ ] Are dense slots not cached across structural changes?
- [ ] Is a store's membership not changed in the middle of an iteration?
- [ ] Is `create_entity()` checked for -1?
- [ ] Do time-dependent systems have `requires_time = true`?

---

[← Performance](09-performance.md) | [Contents](README.md) | [Full example →](11-full-example.md)
