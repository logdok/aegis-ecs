[← Quick start](02-quick-start.md) | [Contents](README.md) | [Components →](04-components-and-stores.md)

---

# 3. World, entities, lifecycle

`EcsWorld` is the allocator of entity identifiers and the registry of stores. It
does not hold game data; it answers the questions "which entities are alive" and
"which stores exist".

---

## 3.1. Creating a world

```gdscript
var world := EcsWorld.new(10000)   # capacity: 10,000 simultaneously live entities
```

The capacity is set once, and all internal buffers are allocated **immediately**.
The world **does not grow on its own** — this is a deliberate decision. A hidden
allocation in the hot loop with tens of thousands of entities causes a hitch on a
weak device, and a hitch that happens once every few minutes at a random moment
is almost impossible to debug.

If capacity might run out, read about explicit growth and the automatic policy in
[section 7.3](07-time-events-capacity.md#73-capacity-and-growth-policy).

### The order of building a world

```gdscript
var world := EcsWorld.new(10000)

# 1. First ALL the stores.
world.register_store(positions, TYPE_POSITION)
world.register_store(velocities, TYPE_VELOCITY)
world.register_store(enemy_tag, TYPE_ENEMY)

# 2. Then the systems.
scheduler.add_system(...)
scheduler.setup_all(world, context)

# 3. And only now — entities.
var entity: int = world.create_entity()
```

The schema is **locked by the first `create_entity()`**: after it,
`register_store()` returns `false` and prints an error. This is deliberate — a
store registered later would not know about the already created entities, and its
sparse array would be inconsistent.

The type identifier (`TYPE_POSITION` and so on) is any integer you like, usually
constants of your own enum. The world uses it only for `get_store()` and
diagnostics; it does not affect speed.

---

## 3.2. An entity is a number

```gdscript
var entity: int = world.create_entity()
if entity < 0:
    return            # the world is full — checking is MANDATORY
```

`create_entity()` returns **-1** when there are no free identifiers left. This is
not an exception or an error — it is the normal state of a full world, and the
calling code is obliged to check for it.

The identifier is a dense index in the range `[0, capacity)`. It directly
addresses each store's `sparse_index`, so it stays the cheapest representation in
the hot loop: no decoding, no checks.

### Batched creation

When many entities are born in one frame — a wave of enemies, an explosion into
particles, cell division — paying the per-call overhead is not worth it:

```gdscript
var buffer := PackedInt32Array()
buffer.resize(256)                                  # once, ahead of time

var spawned: int = world.create_entities(64, buffer)
# spawned can be less than 64 if the world is almost full
```

`buffer` is filled in place (in Godot 4, `Packed*Array` is passed by reference).
That same buffer is then handed to the stores:

```gdscript
var first_slot: int = positions.count      # TAKE IT BEFORE the call
positions.attach_many(buffer, spawned)
for i in spawned:
    positions.x[first_slot + i] = 0.0
```

The new components occupy slots `[first_slot, first_slot + attached)` **in the
same order** the entities were in the buffer.

---

## 3.3. The handle: a reference that survives across frames

A raw identifier is safe **only within a structural epoch** — that is, until
`flush_destroy_queue()` or `reset()` is called. After destruction, the same
number can be handed to a different entity.

So for everything that lives between frames — a turret's target, an effect's
owner, a UI element, a deferred callback, an external queue — there is a
**generational handle**:

```gdscript
var handle: int = world.make_handle(entity)

# ...many frames later:
var current: int = world.entity_from_handle(handle)
if current == EcsWorld.INVALID_ENTITY:
    return          # the target died; the handle is stale
# here current can be used as an ordinary id again
```

A handle is a positive 63-bit number that packs three things:

```
bits  0..23  raw entity id      (up to 16,777,216 slots)
bits 24..47  generation
bits 48..62  world tag
```

**The generation** is a counter that increases every time a slot is freed. So an
old handle to a reused slot does not match on generation and is rejected. This is
protection against the classic **ABA problem**: "the same number, but a different
entity now".

**The world tag** protects against a handle from one world accidentally
resolving in another (relevant if you have several independent simulations).

### The choice rule

| Situation | What to store |
|---|---|
| Within one frame, inside a system | a raw `int` |
| A target, an owner, a subscription, UI, a tween, async | a `handle` |
| Saving to disk, networking | **your own GUID**, not a handle |

A handle is **not** a stable identifier between runs of the game: it contains the
process tag and the generation, which are different on a new run.

### Helper methods

```gdscript
world.create_entity_handle()          # create and get a handle at once
world.is_handle_alive(handle)         # without resolving to an id
world.queue_destroy_handle(handle)    # safe destruction by handle
world.is_handle_pending_destroy(handle)
```

---

## 3.4. Destruction: the most important rule

Once more, because this is the place where every ECS beginner breaks.

```gdscript
world.queue_destroy(entity)     # ONLY marks
world.flush_destroy_queue()     # actually destroys
```

`queue_destroy()` is **idempotent**: if several systems in one frame
independently decide to kill the same entity, it lands in the queue once.

`flush_destroy_queue()` is a **structural sync point**. It:

1. checks the generation of every queue entry;
2. detaches the entity from every registered store;
3. performs swap-remove and cleanup hooks;
4. marks the entity dead;
5. increments the generation;
6. and only then returns the id to the free pool.

### Where to call it

Use the ready-made `EcsReaperSystem`, registered **last**:

```gdscript
scheduler.add_system(MovementSystem.new())
scheduler.add_system(CombatSystem.new())
scheduler.add_system(EcsReaperSystem.new(world))    # ← last
```

Technically the flush can sit at several explicit phase boundaries. But
**never** inside a system, and you can **never** cache a dense slot across that
boundary:

```gdscript
# WRONG
var slot: int = positions.index_of(entity)
world.flush_destroy_queue()          # swap-remove could have moved data here
positions.x[slot] = 0.0              # writing into someone else's component
```

A handle cures a stale **entity reference**, but not a stale **dense slot**. The
slot must be taken again after any structural change.

### Batched marking

```gdscript
world.queue_destroy_many(buffer, count)
```

---

## 3.5. Reset: restarting a level with no allocations

```gdscript
world.reset()
```

All entities "die", all stores are cleared — **with no allocations**: the arrays
are simply refilled. Store registrations are kept; you must not and cannot call
`register_store()` again.

`reset()` invalidates all active handles: the generation of every live entity is
increased.

---

## 3.6. Diagnostics

```gdscript
world.get_live_count()             # how many entities are alive
world.get_free_count()             # how many ids are left
world.get_retired_count()          # slots with an exhausted generation
world.get_pending_destroy_count()  # how many are waiting in the queue
world.get_load_factor()            # live / capacity, in [0, 1]
world.capacity
world.structural_version           # a monotonic counter of structural changes
```

### Integrity check

```gdscript
if not world.validate_integrity():
    breakpoint
```

A full check of the allocator, the destroy queue and all sparse sets: whether the
counters add up, whether there are duplicates in the free list, whether the
sparse↔dense mappings are bijective, whether a component is attached to a dead
entity.

The check is **linear in capacity** and creates temporary buffers. It is a
development tool: call it from tests, from a debug panel or in a fuzz loop, but
**not from a production frame**.

`validate_integrity(false)` does not print errors and only returns a `bool` —
handy for tests.

---

## 3.7. Multiple worlds

Nothing stops you from having several independent `EcsWorld` instances — for
example, one per match, per level or per parallel simulation. The world tag in
the handle guarantees that a reference from one world will not resolve in
another.

Limitation: there are enough tags for 32,767 worlds created over the process
lifetime (they are not reused). Once exhausted, worlds keep working with raw ids,
but the handle API reports an error. In practice this is an unreachable limit
unless you create a new world every frame.

---

## Chapter summary

1. Capacity is fixed at creation; the world does not grow on its own.
2. All stores are registered **before** the first entity.
3. `create_entity()` can return **-1** — always check.
4. A raw id is for within the frame; a **handle** is for across frames; **your
   own GUID** is for a file.
5. `queue_destroy()` marks, `flush_destroy_queue()` destroys — at **exactly one
   point in the frame**, usually via `EcsReaperSystem`.
6. Do not cache a dense slot across a structural change.

---

[← Quick start](02-quick-start.md) | [Contents](README.md) | [Components →](04-components-and-stores.md)
