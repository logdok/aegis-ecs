[← World and entities](03-world-entities-lifecycle.md) | [Contents](README.md) | [Systems →](05-systems-and-scheduler.md)

---

# 4. Components and stores

A store is a container for one component type's data across all entities. This is
where all the memory layout that ECS exists for lives.

---

## 4.1. How a store is built

Every store is a **sparse set** of two arrays running in opposite directions:

```
sparse_index[entity_id] → dense slot, or -1 if there is no component
dense_entities[slot]    → which entity this slot belongs to
```

Plus the arrays of **the data itself**, indexed by **the same dense slot**.

```gdscript
var slot: int = positions.index_of(entity)   # entity 42 → slot 5
if slot != -1:
    print(positions.x[slot])                 # look up data by 5, not by 42
```

> **The most common beginner mistake:** indexing the data array by the entity
> identifier. `positions.x[42]` is almost always someone else's component or
> garbage. Data is addressed by the **slot**, not the id.

Three fields are deliberately public: `sparse_index`, `dense_entities` and
`count`. Systems read them directly in hot loops, and a method call in GDScript
costs several times more than an array element read (measured: ~90 ns vs ~20 ns).
Outside the class, treat them as **read-only**.

---

## 4.2. `EcsPackedStore` — the recommended way

```gdscript
class_name EnemyStore
extends EcsPackedStore

var position: PackedVector3Array = PackedVector3Array()
var health: PackedFloat32Array = PackedFloat32Array()
var speed: PackedFloat32Array = PackedFloat32Array()
var tint: PackedColorArray = PackedColorArray()

func _init() -> void:
    track(&"position", &"health", &"speed", &"tint")
```

That is all. You declare typed fields and name them once — memory allocation,
capacity growth and data relocation on removal are implemented by the base class.

**Supported field types:** any `Packed*Array`, and also a plain `Array` for
fields holding objects or resources.

### Why this is not slower

The fields stay ordinary typed class members. In the hot loop you read them
directly:

```gdscript
var hp: PackedFloat32Array = enemies.health
for slot in enemies.count:
    hp[slot] -= poison_damage
```

The generic work happens only during allocation and removal. And even there
`EcsPackedStore` **does not lose** to a hand-written store: it implements a
batched relocation that fetches the arrays once for the whole operation rather
than once per moved element. In measurements (chapter 9), destroying 10,000
entities with four components each: hand-written store — 7.55 ms, declarative —
7.58 ms. The difference is within the margin of error.

### Useful methods

```gdscript
store.get_tracked_field_count()      # how many fields are registered
store.clear_slot(slot)               # write zeros into all fields of this slot
store.refresh_tracked_arrays()       # if a field was assigned a whole new array
```

Call `clear_slot()` right after `attach()` if the store has optional fields that
the creation path does not always fill: slots are reused, and a fresh component
would otherwise start life with the previous owner's garbage.

`refresh_tracked_arrays()` is only needed in the rare case where a field was
**assigned wholesale** (`health = PackedFloat32Array()`) rather than modified in
place.

---

## 4.3. `EcsTagStore` — a component with no data

Sometimes a system does not need to know anything about an entity except the
fact that it belongs to a category: "this is an enemy", "this is a projectile",
"this can be picked up".

```gdscript
var hostile_tag := EcsTagStore.new()
world.register_store(hostile_tag, TYPE_HOSTILE)

hostile_tag.attach(entity)
if hostile_tag.has(entity):
    ...

# The most valuable part — dense iteration over the whole category:
var hostiles: PackedInt32Array = hostile_tag.dense_entities
for i in hostile_tag.count:
    var enemy: int = hostiles[i]
```

A tag has no data arrays, so its removal relocates nothing at all — it is the
cheapest store in the library.

---

## 4.4. `EcsComponentStore` — a hand-written store

The lower level. You need it when the layout is non-standard: for example, a
bit-mask field, data in a custom format, or a payload that must be relocated
non-trivially.

The subclass **must** implement two methods:

```gdscript
class_name CustomStore
extends EcsComponentStore

var packed_flags: PackedInt32Array = PackedInt32Array()

# 1. Allocate your arrays for the world's capacity.
func _reserve_dense(dense_capacity: int) -> void:
    packed_flags.resize(dense_capacity)

# 2. Relocate data on swap-remove.
func _relocate_dense(from_slot: int, to_slot: int) -> void:
    packed_flags[to_slot] = packed_flags[from_slot]
```

> **Forgetting `_relocate_dense()` is a classic mistake.** Removal starts
> silently losing data: the last element moves into the removed one's place, but
> its payload stays where it was. There will be no message in the console. This
> is exactly why `EcsPackedStore` exists for ordinary data.

---

## 4.5. Optional hooks

These methods are **deliberately not declared** in the base class. The library
detects their presence via `has_method()`: **define it — it is used; don't
define it — it costs nothing**. There is no flag here that you could forget to
set.

| Hook | Purpose |
|---|---|
| `_grow_dense(prev, next)` | Enables `world.reserve_capacity()`. Must preserve all data in `[0, count)`. |
| `_relocate_dense_batch(from, to, n)` | Batched relocation: fetch the arrays once for the whole operation. |
| `_release_dense(slot)` | Free a `Resource`/`RID`/`Callable` before it is overwritten. |
| `_clear_relocated_dense(slot)` | Clear the duplicate in the slot the data moved from. |
| `_clear_dense(active_count)` | Bulk cleanup on `clear()`/`reset()`. |

`EcsPackedStore` and `EcsTagStore` already define `_grow_dense`, so they support
capacity growth with no action on your part.

### Capacity growth for a hand-written store

```gdscript
func _grow_dense(_previous_capacity: int, dense_capacity: int) -> void:
    packed_flags.resize(dense_capacity)     # resize keeps the prefix [0, count)
```

You can check it like this:

```gdscript
if store.supports_capacity_growth():
    ...
```

If at least one registered store has no `_grow_dense`, `world.reserve_capacity()`
returns `false` **without changing anything**.

---

## 4.6. Components that own resources

If the payload contains a `Resource`, `RID`, `Callable` or `Object`, it is not
enough to just relocate the value — you also have to free what is being removed.

```gdscript
class_name MaterialStore
extends EcsPackedStore

var materials: Array = []          # a plain Array for objects

func _init() -> void:
    track(&"materials")

# Called on the slot being REMOVED, BEFORE the data is relocated.
func _release_dense(dense_slot: int) -> void:
    var rid = materials[dense_slot]
    if rid != null:
        RenderingServer.free_rid(rid)
    materials[dense_slot] = null

# Called on the slot the data moved FROM.
# Here we ONLY clear the duplicate — ownership has already moved elsewhere.
func _clear_relocated_dense(dense_slot: int) -> void:
    materials[dense_slot] = null

# Bulk cleanup on clear() / world.reset().
func _clear_dense(active_count: int) -> void:
    for slot in active_count:
        if materials[slot] != null:
            RenderingServer.free_rid(materials[slot])
            materials[slot] = null
```

**Order matters.** `detach()` first calls `_release_dense()` on the slot being
removed, and only then relocates the payload from the last slot and calls
`_clear_relocated_dense()`. Mixing these two operations means either a resource
leak or a double free.

If you define `_clear_relocated_dense()` without `_release_dense()`, the library
prints an error when the store is registered: this almost always means a leak.

---

## 4.7. Core operations

```gdscript
var slot: int = store.attach(entity)     # idempotent; -1 on overflow
store.detach(entity)                     # safe, even if there is no component

store.has(entity)                        # bool
store.index_of(entity)                   # slot or -1
store.entity_at(slot)                    # the entity that owns the slot
store.count                              # how many components
store.clear()                            # empty with no allocations
```

> `has()`, `index_of()` and `entity_at()` **deliberately do not check bounds** —
> they are hot-loop primitives. Passing the id of a non-existent entity here is
> a bug in the calling code. Structural entry points (`attach`, `detach` and
> their batched forms) do check bounds, because they run far less often.

### Batched operations

```gdscript
var first: int = store.count
var attached: int = store.attach_many(ids, count)
# new slots: [first, first + attached)

var removed: int = store.detach_many(ids, count)
```

`attach_many()` skips entities that already have the component, so `attached` can
be less than `count`.

---

## 4.8. How to split data across stores

A practical question: one big store or many small ones?

**Keep together what is read together.** If the movement system reads position
and velocity every frame, it makes sense to put them in one store: then no
`sparse_index` lookup is needed and iteration goes over a single dense array.

**Separate what is used rarely or on its own.** A component that every tenth
entity has would, in a shared store, force the other nine to carry unfilled
fields — and, worse, take up space in the hot loop's cache lines.

**Move flag-like traits into tags.** "Stunned", "invulnerable", "in water" are an
`EcsTagStore`, not a `bool` in a big store: a tag gives you a dense list of
exactly those it applies to.

An example layout for a game:

| Store | Fields | Who reads it |
|---|---|---|
| `Transform` | position, yaw | almost every system |
| `Locomotion` | velocity, speed | movement, targeting |
| `Health` | current, max | damage, death |
| `MissileLauncher` | cooldown, range | only the shooting system (few entities) |
| `HostileTag` | — | spawning, target search |
| `StunnedTag` | — | movement (exclusion) |

---

## Chapter summary

1. Data is addressed by the **dense slot**, not the entity id.
2. For ordinary data use **`EcsPackedStore`** — no boilerplate and no speed
   loss.
3. `EcsTagStore` is for traits with no data.
4. A hand-written `EcsComponentStore` **must** implement `_reserve_dense` and
   `_relocate_dense`.
5. Optional hooks are **detected automatically**: define it — it works.
6. Stores with `Resource`/`RID` implement `_release_dense` **and**
   `_clear_relocated_dense` — the order they are called in is critical.
7. Read together — store together; move the rare and the separate out.

---

[← World and entities](03-world-entities-lifecycle.md) | [Contents](README.md) | [Systems →](05-systems-and-scheduler.md)
