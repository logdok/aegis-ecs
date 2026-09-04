[← Contents](README.md)

---

# Aegis ECS architecture

This document describes the extended Aegis model for a large game. The core
principle has not changed: the fastest path is still a plain loop over dense
`Packed*Array`s. Safety and generality are added as separate cold-path APIs, so a
particle or a projectile does not pay for features it does not use.

This is a **decision reference**, not a tutorial. If you are looking for "how to
use this", start with the [guide](README.md).

## Layers

```text
EcsWorld
  ├─ raw-id allocator + deferred destroy queue
  ├─ batched create_entities() / queue_destroy_many()
  ├─ generation + world tag → a safe cross-frame handle
  ├─ registry of EcsComponentStore sparse sets
  └─ explicit capacity barriers and integrity checks

Stores
  EcsComponentStore        sparse set, auto-detection of optional hooks
    ├─ EcsPackedStore      declarative: track() the fields — and nothing else
    └─ EcsTagStore         no payload, specialized batch removal

Iteration
  ├─ direct sparse loop     fastest, joined by hand
  ├─ EcsView                a live filter with no allocations
  └─ EcsQuery               a pre-allocated membership cache

Execution
  EcsScheduler
    ├─ registration order is behaviour
    ├─ system/phase switches, requires_time skipping
    ├─ read/write metadata and conflict analysis
    └─ profiling (per-frame accumulation + a smoothed average)

Ready-made systems
  ├─ EcsReaperSystem            the single point of destruction
  └─ EcsCapacityPolicySystem    grows before the world fills up

Helpers
  ├─ SimulationClock        fixed step, time scale, safety valve
  ├─ UniformSpatialGrid     broadphase on counting sort, flat 2D mode
  └─ AngleMath              turn an angle along the shortest path
```

## Raw id and the generational handle

A raw id is an index from `0` to `capacity - 1`. It directly addresses
`sparse_index`, so it stays the cheapest representation in the hot loop.

A raw id must not be treated as a stable reference across a structural sync point.
After destruction, the same index can be handed to a different entity. For a
target, an owner, a UI selection, a tween, a signal, an async callback and an
external queue, a positive 63-bit handle is used:

```text
bits  0..23  raw entity id     (up to 16,777,216 slots)
bits 24..47  generation        (up to 16,777,215 lives per slot)
bits 48..62  in-process world tag
bit      63  0
```

```gdscript
var entity: int = world.create_entity()
var handle: int = world.make_handle(entity)

# Many frames later:
entity = world.entity_from_handle(handle)
if entity == EcsWorld.INVALID_ENTITY:
	return
```

A handle is rejected if the world tag, the generation, the range or the "alive"
state does not match. On generation overflow the slot becomes `retired` and is
never handed out again: an old handle cannot come back to life even in theory.
World tags are not reused; after 32,767 worlds created in one process, new worlds
work with raw ids but the handle API reports an error.

A runtime handle is **not** a save/network ID. Between runs, use your own GUID or
a domain stable key.

## Lifecycle and structural epochs

```text
FREE → ALIVE → PENDING_DESTROY → FREE
                              ↘ RETIRED on generation overflow
```

`queue_destroy*()` does not change stores. A marked entity and its handle stay
valid until `flush_destroy_queue()`. The flush is a structural sync point:

1. re-checks the generation-stamped key from the queue;
2. detaches the entity from every store;
3. performs swap-remove and cleanup hooks;
4. marks the entity dead;
5. increments the generation;
6. and only then returns the raw id to the free stack.

The flush can sit at several phase boundaries. It cannot run in the middle of a
system or keep a dense slot across that boundary. A generational handle cures a
stale entity reference, but not a stale dense slot.

`reset()` invalidates the handles of all active and marked entities, clears the
stores and the queue, but keeps the registrations and the capacity. The schema is
locked by the first successful `create_entity()`; all stores must be registered
in advance.

## Stores and reference cleanup

A store is a sparse set with a bidirectional mapping:

```text
sparse_index[entity] → dense slot or -1
dense_entities[slot] → entity
payload[slot]        → component data
```

A subclass always implements `_reserve_dense()` and `_relocate_dense()`. If the
payload contains references, hooks are added:

```gdscript
func _release_dense(slot: int) -> void:
	owner_api.release(resources[slot]) # the API needed for an owned RID/native handle
	resources[slot] = null

func _clear_relocated_dense(slot: int) -> void:
	resources[slot] = null # ownership already moved; do not free again

func _clear_dense(active_count: int) -> void:
	for slot in active_count:
		# free the ownership of every active payload
		resources[slot] = null
```

Detach first calls `_release_dense(removed_slot)`, then relocates the last payload
and calls `_clear_relocated_dense(last_slot)`. These operations must not be mixed:
otherwise the removed RID leaks and the relocated one can be freed twice. Without
the hooks, the pre-allocated array keeps holding removed `Resource`, `RID`,
`Callable` or `Object` values.

`structural_version` changes on a new attach, a successful detach, a non-empty
clear and capacity growth. A payload write does not change it: the query
membership stays the same.

## Choosing between the direct loop, View and Query

### The direct loop

Use it in the hottest systems with a known schema. The smallest store is chosen
as the driver, and the rest of the components are checked via sparse arrays.

```gdscript
var entities := velocities.dense_entities
var position_slots := positions.sparse_index
for velocity_slot in velocities.count:
	var entity: int = entities[velocity_slot]
	var position_slot: int = position_slots[entity]
	if position_slot == -1:
		continue
```

### EcsView

`EcsView` resolves the required/excluded type IDs once. `refresh_driver()` picks
the smallest required store, `matches()` reads the current sparse sets. After
`configure()` the steady-state API builds no result array and allocates nothing.

A View is more convenient than joining by hand, but `matches()` remains a method
call per candidate. For the hottest systems, take the sparse arrays from the View
(`get_required_sparse()`) and inline the check into your own loop.

### EcsQuery

`EcsQuery` materializes entity ids into a pre-allocated buffer. By default its
size equals `world.capacity`; an optional `maximum_results` limits the buffer for
a query with a known upper bound. Query tracks `structural_version` and skips the
rebuild if the membership did not change.

```gdscript
if query.refresh():
	# the membership really changed
for index in query.count:
	var entity: int = query.entity_at(index)
```

The rebuild lifts all participating sparse arrays into local variables and
specializes the most common arities (1 required, 1 excluded, and so on), so it
does not call `matches()` at all. This gave 5.4x.

With a bounded buffer, `count` never exceeds `maximum_results`, and
`is_truncated()` reports that there were more matching entities. Without a limit,
the result memory is roughly `4 bytes × world.capacity` per Query: 100 full
queries at a capacity of 1,000,000 would take about 381 MiB.

`get_entities_unsafe()` removes the method call, but the buffer is considered
read-only and the alias must not be kept across `refresh()` or
`reserve_capacity()`.

View/Query require at least one required type: the world deliberately does not
keep a second dense list of "everyone alive" just for a component-less query.

## The scheduler, phases and metadata

The scheduler never sorts systems. Registration order remains the complete
specification of behaviour. A phase is a filter and metadata:

```gdscript
scheduler.add_system(InputSystem.new(), 100)
scheduler.add_system(MovementSystem.new(), 200)
scheduler.add_system(RenderUploadSystem.new(), 300)
scheduler.add_system(EcsReaperSystem.new(world), 400)
```

An ordinary frame uses `execute_all(delta)`. If phases are called from different
places, close the previous frame once:

```gdscript
scheduler.begin_frame()
scheduler.execute_phase(100, delta)
scheduler.execute_phase(200, delta)
scheduler.execute_phase(300, delta)
scheduler.execute_phase(400, delta)
```

Measurements **accumulate** between two `begin_frame()` calls, so a fixed-step
frame that runs the simulation phase four times reports the total cost of those
four sub-steps — that is, what actually landed in the frame budget. The smoothed
average is folded once per frame, not per sub-step.

`enabled` and phase toggling do not remove systems, so the profiler indices are
stable. A disabled system gets timing `0` and `was_system_executed() == false`.

### `requires_time` skipping

Pause is a zero step, not a skipped frame. Historically every time-dependent
system had to begin with `if delta <= 0.0: return`, and forgetting that line was a
silent bug. Now a system declares `requires_time = true` in `_init()`, and the
scheduler skips the call entirely — which is both safer and slightly faster.

`EcsReaperSystem` deliberately has `requires_time = false`: entities marked for
destruction before the pause must be cleaned up, otherwise they hang in the queue
and in every store for the whole duration of the pause.

### Access metadata

Set in `_init()`:

```gdscript
declare_read(TYPE_INPUT)
declare_write(TYPE_POSITION)
declare_structural_write(TYPE_SLEEPING)
writes_world_structure = true  # create/destroy/reset
complete_access_metadata()
```

The metadata does not change the order and adds no runtime checks. It is used for
`validate_pipeline()`, the View/Query owner check and `systems_conflict()`. The
latter conservatively answers whether two systems could enter a future parallel
batch. Until a system has called `complete_access_metadata()`, its access is
considered unknown and it conflicts with any other — so old code cannot
accidentally end up in an unsafe parallel batch. The current scheduler remains
sequential. `writes_world_structure` always conflicts with every system:
create/destroy/reset change the validity of raw ids and of every View even for a
system with no declarations.

After `add_system()` the `system_phase` field is frozen. A runtime move is done
by `scheduler.set_system_phase(index, phase)`: this keeps a phase's enable state
from diverging from the system. One system instance cannot be shared between two
schedulers.

`teardown_all()` calls the systems in reverse order — resources are torn down
like a stack relative to `setup`.

## Capacity growth

The steady-state frame never grows automatically. If the forecast changed:

```gdscript
# loading screen / stopped pipeline
world.reserve_capacity(200_000)
```

The world and all registered stores grow together; existing raw ids, handles and
dense slots are preserved. The game's own external buffers (`MultiMesh`, physics
batches, network arrays) the library cannot grow — that is the loading code's
job. Query adapts its cache on the next `refresh()`.

Growth for a custom store is opt-in through the mere fact of defining the hook.
Initialization and growth are separated so that an accidental repeated
`_reserve_dense()` cannot wipe live data:

```gdscript
func _grow_dense(_old_capacity: int, new_capacity: int) -> void:
	positions.resize(new_capacity) # obliged to preserve [0, count)
```

There is no separate flag: a store supports growth if and only if `_grow_dense()`
is defined. This is checked once, at registration, via `has_method()` — which is
exact, because the base class deliberately **does not declare** the method.
Publicly the state is available as `store.supports_capacity_growth()`.
`EcsPackedStore` and `EcsTagStore` always define the hook.

Before changing any array, the world checks the capacity and growth support of
every store. If at least one is not opt-in, `reserve_capacity()` returns `false`
without changing either the world or the stores. There is no direct public growth
of an individual store: its capacity cannot be desynchronized from its owner
through the standard API.

## Auto-detection of optional hooks

The same mechanism applies to all optional store hooks:

```text
_grow_dense               -> enables reserve_capacity()
_relocate_dense_batch     -> enables batched payload relocation
_release_dense            -> enables the ownership path of detach
_clear_relocated_dense    -> clearing the moved-from duplicate
_clear_dense              -> bulk cleanup on clear()/reset()
```

The base class declares none of them, so `has_method()` gives an exact answer to
"did the subclass define it". This eliminates a whole class of silent bugs:
otherwise the feature would be governed by a boolean flag that can be set wrong
(forgot to set it → a resource quietly leaks; set it needlessly → you pay for an
unused path). The cost of a `call()` dispatch in GDScript is practically equal to
a direct call (measured: 94.6 ns vs 91.9 ns), so exact dispatch is not paid for.

The price of skipping a hook is real: an empty virtual call costs ~90 ns against
~20 ns for an array element read. On 10,000 entities × 4 components that is ~7 ms
per frame if the hooks were called for nothing.

## Batched destruction

`flush_destroy_queue()` is the most expensive structural operation: destroying one
entity means detaching it from **every** registered store. With 12 stores and
10,000 entities that is 120,000 pairs.

The implementation is store-major, not entity-major, and adaptive:

```text
1. Resolve the queue keys and compact the survivors into the front of the same
   array. That array then serves as the list of victims — there is no separate
   scratch buffer.
2. For each store, pick the cheaper traversal:
      count <= reaped * 2   -> detach_flagged(flags)  — O(count)
      otherwise             -> detach_many(queue, n)  — O(reaped)
3. Finish the lifecycle: alive = 0, generation++, return the id to the free stack.
```

**Why store-major.** Inside `detach_many()` the sparse/dense arrays live in local
variables, so a pair where there is no component costs one local array read
instead of an object field read plus a method call. A typical entity has only
some of the components, so it is this skip path that dominates.

**Why adaptive.** A store on a single entity (a turret, the player) should not
scan 10,000 victims. Iterating its own dense array with a byte-flag check costs
O(count).

**Why `detach_flagged()` is faster on a mass death.** Knowing in advance which
elements are doomed, it does not move a doomed element into a just-freed slot only
to remove it the next step: the marked elements are first cut from the tail (they
need no relocation at all), and only then do the survivors fill the holes. When
destroying the whole population there are **zero** relocations instead of one per
removal.

The threshold `count <= reaped * 2` is chosen like this: the saving is
`removed × f` relocations (f is the fraction of the store caught by the removal),
the extra work is `(count - reaped)` iterations. At ~200 ns per relocation and
~20 ns per iteration, the crossover is around 2–3x; a conservative 2x is taken.

`detach_many()` (without flags) cannot relocate less: the list of victims gives no
cheap answer to "is the tail element also doomed?".

### Batched payload relocation

When a store has no ownership hooks, nothing reads the payload as the loop
proceeds, so all relocations can be recorded and applied in one pass in the same
order — which is equivalent to interleaving. The subclass then fetches its arrays
once for the whole operation, not once per relocation:

```gdscript
func _relocate_dense_batch(from_slots, to_slots, move_count) -> void:
	for i in _tracked_arrays.size():
		var array = _tracked_arrays[i]
		for move in move_count:
			array[to_slots[move]] = array[from_slots[move]]
```

Measured: lifting the array access out of the inner loop gives 43 → 23 ns per
relocation. That is why `EcsPackedStore` does not lose to a hand-written store
(7.58 ms vs 7.55 ms on 10k × 4), despite the generality.

A store with ownership uses the interleaving path: `_release_dense()` is obliged
to run **before** the payload is overwritten, so the relocation cannot be
deferred.

## Validation and testing

`world.validate_integrity()` checks:

- `live + free + retired == capacity`;
- uniqueness of the free list and the destroy queue;
- that the flags match the queue;
- the "alive" state of every entity in a store;
- the sparse↔dense bijection and slot bounds;
- equal capacity of the world and the stores.

The check is linear and creates temporary debug buffers, so it must not run every
production frame.

```bash
godot --headless --script res://addons/aegis_ecs/tests/test_advanced_ecs.gd
godot --headless --script res://addons/aegis_ecs/tests/test_ecs_features.gd
```

`test_advanced_ecs.gd` covers the handle ABA check, rejecting a foreign world's
handle, reset/growth, cleanup hooks, View/Query caching, scheduler control and
5,000 random structural operations.

`test_ecs_features.gd` additionally checks the batched paths **differentially**:
the same removals are run through `detach()` one at a time and through
`detach_many()` / `detach_flagged()`, after which the final entity → payload
mapping is compared. The optimized path is obliged to be indistinguishable from
the naive one, and this is the only way to be sure of that reliably.

`_relocate_dense()` cannot be universally checked for an arbitrary payload. Every
custom store must have its own relocation test with distinguishable values in
every field.

## Recommended structure for a large game

- One `EcsWorld` per independent simulation/match, not a global singleton.
- Type IDs are a single module enum, registered before the first entity.
- Hot cohesive data may be kept in one store; optional traits and rare subsystems
  are moved out into separate stores/tags.
- Raw ids do not leave systems; public services, UI and callbacks get a handle or
  a domain GUID.
- Structural writers are grouped into clear phase boundaries.
- Direct loops are used after profiling, not by default everywhere.
- `validate_integrity(false)` runs in CI/fuzz and on a debug-panel command.
- The save/network layer serializes the domain schema, not the internal dense
  slots.
- Data-only stores extend `EcsPackedStore`; a hand-written `EcsComponentStore`
  remains for non-standard layouts.
- Destruction goes through a single `EcsReaperSystem`, registered last;
  `EcsCapacityPolicySystem` right after it.
- Time-dependent systems declare `requires_time = true` instead of a manual
  `delta <= 0.0` check.
- A reaction to appearance/death goes through the store's opt-in change log, not
  through signals: the reader sits right after the reaper.
- A controlled time rate goes through `SimulationClock` with a fixed step; a raw
  `delta × time_scale` desynchronizes the simulation across thresholds.

## Deliberate limitations

Aegis provides no archetype chunks, no automatic parallel scheduler, no
rollback/snapshot protocol and no universal serialization. Reactivity exists, but
as an explicit opt-in log of structural changes rather than signals: the cost of
enabling it is visible, and a disabled log costs one check per structural
operation.

The newer APIs give a safe foundation for a large game without turning the
compact GDScript core into a hidden runtime with unpredictable cost.

---

[← Contents](README.md)
