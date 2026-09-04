[← Systems](05-systems-and-scheduler.md) | [Contents](README.md) | [Time and events →](07-time-events-capacity.md)

---

# 6. Finding the entities you want

A typical system processes not all entities but those that have a certain set of
components: "everyone who has a position AND a velocity but is NOT stunned".

Aegis has three levels for this, from fastest to most convenient. This is not a
"bad, medium and good way" — it is three different trade-offs, and each is right
in its own place.

---

## 6.1. Level 1: the direct loop (fastest)

The idea is simple: **drive the iteration by the dense array of the smallest
store**, and fetch the rest of the components through `sparse_index`.

```gdscript
func execute(delta: float) -> void:
    var velocities: VelocityStore = _context.velocities
    var positions: PositionStore = _context.positions

    # Local aliases — mandatory before the loop.
    var owners: PackedInt32Array = velocities.dense_entities
    var pos_slots: PackedInt32Array = positions.sparse_index
    var vx: PackedFloat32Array = velocities.x
    var px: PackedFloat32Array = positions.x

    for dense in velocities.count:
        var slot: int = pos_slots[owners[dense]]
        if slot < 0:
            continue                      # this entity has no position
        px[slot] += vx[dense] * delta
```

**Why drive by the smallest store.** If 300 entities have a velocity but 10,000
have a position, iterating velocities gives 300 iterations, and iterating
positions gives 10,000 with 9,700 wasted checks.

**When to use it.** In the hottest systems with a schema known in advance. This
is the library's main working tool: measured at ~57 ns per element, including the
lookup of the second component.

There is deliberately no query abstraction in the core precisely because, at
10,000 entities × 12 systems, it would be visible in the profile.

---

## 6.2. Level 2: `EcsView` (no allocations)

When the set of components is more complex than "two specific stores", or when
you need **exclusions**, it is more convenient to describe the condition
declaratively.

```gdscript
var _moving := EcsView.new()

func setup(world: EcsWorld, context) -> void:
    _moving.configure(
        world,
        PackedInt32Array([TYPE_POSITION, TYPE_VELOCITY]),   # required
        PackedInt32Array([TYPE_STUNNED]),                   # excluded
        self,                                               # owner (for validation)
    )

func execute(delta: float) -> void:
    _moving.refresh_driver()                    # pick the smallest store
    var driver := _moving.get_candidate_store()
    var candidates: PackedInt32Array = driver.dense_entities

    for dense in driver.count:
        var entity: int = candidates[dense]
        if not _moving.matches(entity):
            continue
        # ...
```

`EcsView` **materializes nothing and allocates nothing**. `configure()` is a cold
operation (once, in `setup`), `refresh_driver()` picks the smallest of the
required stores, and `matches()` does direct sparse-set checks.

### A faster variant: inline the check

`matches()` is a method call for every candidate, and a call in GDScript costs
~90 ns. In a hot system it is better to take only the **resolved arrays** from the
View and inline the check into your own loop:

```gdscript
_moving.refresh_driver()
var driver := _moving.get_candidate_store()
var candidates: PackedInt32Array = driver.dense_entities
var health_slots: PackedInt32Array = _moving.get_required_sparse(1)
var stunned_slots: PackedInt32Array = _moving.get_excluded_sparse(0)

for dense in driver.count:
    var entity: int = candidates[dense]
    var health_slot: int = health_slots[entity]
    if health_slot == -1 or stunned_slots[entity] != -1:
        continue
    # ...
```

This way you get the convenience of the description and the speed of the direct
loop at the same time. `get_driver_required_index()` tells you which store became
the driver — you do not need to check it, membership in it is guaranteed by the
iteration itself.

---

## 6.3. Level 3: `EcsQuery` (cached result)

`EcsQuery` **materializes** the intersection into a pre-allocated buffer and
rebuilds it only when the membership actually changed.

```gdscript
var _query := EcsQuery.new()

func setup(world: EcsWorld, context) -> void:
    _query.configure(
        world,
        PackedInt32Array([TYPE_POSITION, TYPE_HEALTH]),
        PackedInt32Array([TYPE_INVULNERABLE]),
        self,
    )

func execute(_delta: float) -> void:
    _query.refresh()                     # rebuilds only if needed
    for index in _query.count:
        var entity: int = _query.entity_at(index)
        # ...
```

`refresh()` returns `true` if the cache was rebuilt and `false` if the membership
did not change. It tracks the `structural_version` of every participating store.

**What invalidates the cache:** `attach`, `detach`, `clear`, capacity growth.
**What does NOT invalidate it:** writing to the payload. Changed health — the
query membership is the same.

That is the point of `EcsQuery`: if the intersection is read by several systems
or changes rarely, the rebuild simply does not happen. In measurements, a cache
miss costs ~0.9 ms on 10,000 candidates, and **a hit costs 0.001 ms**.

### Limiting the buffer size

By default the result is allocated at `world.capacity`. For a narrow query this
is wasteful:

```gdscript
_query.configure(world, required, excluded, self, 256)   # at most 256 results

_query.refresh()
if _query.is_truncated():
    push_warning("result truncated — more than 256 matched")
```

Without a limit, each query takes roughly `4 bytes × capacity`. A hundred full
queries at a capacity of 1,000,000 is about 381 MiB. For a large schema, either
set limits or use a View / the direct loop.

### Fast access to the buffer

```gdscript
var entities: PackedInt32Array = _query.get_entities_unsafe()
for index in _query.count:
    var entity: int = entities[index]
```

This removes the per-element method call. The buffer is considered **read-only**,
and the alias must not be kept across `refresh()` or `reserve_capacity()`.

---

## 6.4. How to choose

| | Direct loop | `EcsView` | `EcsQuery` |
|---|---|---|---|
| Iteration speed | highest | high | highest (over the buffer) |
| Preparation cost | none | `refresh_driver()` | `refresh()`, sometimes a rebuild |
| Allocations | none | none | the buffer, once |
| Component exclusions | by hand | yes | yes |
| When to take it | hot system, fixed schema | changing schema, exclusions | intersection read several times or rarely changing |

Practical advice: **start with the direct loop**. Move to a View when the
condition becomes complex and the code stops being readable; to a Query when the
profiler shows the same intersection being built several times per frame.

---

## 6.5. A limitation shared by View and Query

Both require **at least one required type**. The world deliberately does not keep
a second dense list of "everyone alive" just for a component-less query.

If you need to iterate literally everyone — set up a tag that every entity has
and drive the iteration by it.

---

## 6.6. A safety rule

**Do not change the membership of participating stores in the middle of an active
iteration.**

```gdscript
# WRONG
for dense in positions.count:
    var entity: int = positions.dense_entities[dense]
    if should_remove(entity):
        positions.detach(entity)      # swap-remove shifted the array under your feet
```

Correct — mark and remove later:

```gdscript
for dense in positions.count:
    var entity: int = positions.dense_entities[dense]
    if should_remove(entity):
        world.queue_destroy(entity)   # EcsReaperSystem destroys it at end of frame
```

If you need to remove exactly the **component**, not the entity, collect them
into a buffer and call `detach_many()` after the loop.

---

## Chapter summary

1. **The direct loop** is the main tool; drive the iteration by the smallest
   store.
2. **`EcsView`** is a declarative description with no allocations; for speed take
   the sparse arrays from it and inline the check yourself.
3. **`EcsQuery`** is for when the intersection is read many times or rarely
   changes; miss ~0.9 ms, hit ~0.001 ms.
4. Writing to the payload does **not** invalidate a query's cache;
   `attach`/`detach` does.
5. Never change a store's membership in the middle of an iteration.

---

[← Systems](05-systems-and-scheduler.md) | [Contents](README.md) | [Time and events →](07-time-events-capacity.md)
