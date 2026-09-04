[← Components](04-components-and-stores.md) | [Contents](README.md) | [Finding entities →](06-finding-entities.md)

---

# 5. Systems and the scheduler

---

## 5.1. Anatomy of a system

```gdscript
class_name MovementSystem
extends EcsSystem

var _context: Context             # your own class

func _init() -> void:
    system_name = "Movement"       # shows up in profiling
    requires_time = true           # do not run when time is stopped

func setup(_world: EcsWorld, context) -> void:
    _context = context             # cache the reference once

func execute(delta: float) -> void:
    # work with data
    pass
```

### `setup()`

Called **once**, when all stores are registered and the whole pipeline is
assembled. This is the right place to store a reference to the context or to
specific stores.

Caching a reference here is not a violation of the "systems keep no data"
principle: what is cached is a **reference** to an existing store, not a copy of
the data.

The `context` parameter is deliberately **untyped**: the library knows nothing
about your game. Assign it to a typed field in your system — and work with static
typing from then on.

### `execute()`

Called once per frame, in the order the scheduler defines.

### `teardown()`

Called by `scheduler.teardown_all()` in the **reverse** order of registration —
resources are torn down like a stack relative to `setup()`.

---

## 5.2. Registration order is a contract

```gdscript
scheduler.add_system(SpawnSystem.new())          # 1
scheduler.add_system(MovementSystem.new())       # 2
scheduler.add_system(SpatialIndexSystem.new())   # 3
scheduler.add_system(CollisionSystem.new())      # 4
scheduler.add_system(DamageSystem.new())         # 5
scheduler.add_system(EcsReaperSystem.new(world)) # 6
```

The scheduler **never sorts systems**. Registration order is the complete
specification of behaviour.

The rule: **if system B reads what system A writes in the same frame, A is
registered earlier.**

In the example above the neighbour index (3) is rebuilt **after** movement (2)
and **before** collision search (4). Swap 2 and 3 and collisions are looked for
against last frame's positions. There will be no error; there will be a
different game.

Treat this list as an algorithm, not as formatting. In a serious project it is
worth writing a comment next to each line explaining why the system sits exactly
there.

---

## 5.3. Pause and `requires_time`

Pause in this library is a **zero step**, not a skipped frame:

```gdscript
scheduler.execute_all(0.0)      # pause
```

This way rendering, the camera, the HUD and input keep working while the
simulation stands still.

To keep a time-dependent system from running while paused, declare it once:

```gdscript
func _init() -> void:
    system_name = "Movement"
    requires_time = true
```

The scheduler skips the call entirely.

| `requires_time` | What for |
|---|---|
| `true` | Movement, timers, cooldowns, ageing, AI, physics — anything measured in seconds |
| `false` (default) | Rendering, the camera, the HUD, input, buffer uploads, **the reaper** |

> **`EcsReaperSystem` deliberately has `requires_time = false`.** Entities marked
> for destruction before the pause must be cleaned up, otherwise they hang in the
> queue and in every store for the entire duration of the pause.

---

## 5.4. Phases

A phase is a **label and a filter**, not a way to order things. The scheduler
does not sort systems, phases or not.

```gdscript
const PHASE_INPUT: int = 100
const PHASE_SIMULATION: int = 200
const PHASE_PRESENTATION: int = 300

scheduler.add_system(InputSystem.new(), PHASE_INPUT)
scheduler.add_system(MovementSystem.new(), PHASE_SIMULATION)
scheduler.add_system(CollisionSystem.new(), PHASE_SIMULATION)
scheduler.add_system(RenderUploadSystem.new(), PHASE_PRESENTATION)
```

An ordinary frame:

```gdscript
scheduler.execute_all(delta)
```

A fixed-step frame, where the simulation runs several times and presentation runs
once (see [chapter 7](07-time-events-capacity.md)):

```gdscript
scheduler.begin_frame()                       # close the previous frame
for i in substeps:
    scheduler.execute_phase(PHASE_SIMULATION, clock.fixed_step)
scheduler.execute_phase(PHASE_PRESENTATION, delta)
```

`begin_frame()` is mandatory before a series of `execute_phase()` calls: it ends
the previous frame's measurement and zeroes the counters. `execute_all()` calls
it itself.

**Timing measurements accumulate** between two `begin_frame()` calls. So a frame
with four sub-steps shows the total cost of those four calls — that is, exactly
what actually landed in the frame budget.

### Switches

```gdscript
scheduler.set_system_enabled(index, false)   # disable one system
scheduler.set_phase_enabled(PHASE_AI, false) # disable a whole group
scheduler.set_system_phase(index, phase)     # move a system to a different phase
var index: int = scheduler.find_system("Movement")
```

A disabled system keeps its index in the profiler (so the table does not "jump")
and shows zero time.

The `system_phase` field is **frozen after `add_system()`**. You can change the
phase only through `scheduler.set_system_phase()` — this keeps the phase's
enabled/disabled state from diverging from the system.

One `EcsSystem` instance belongs to **one** scheduler. For a different pipeline,
create a new instance.

---

## 5.5. Profiling

The main performance-diagnostics tool — right on the device.

```gdscript
for i in scheduler.get_system_count():
    print("%-24s %6d µs   (avg %6d)" % [
        scheduler.get_system_name(i),
        int(scheduler.get_timing_usec(i)),
        int(scheduler.get_average_timing_usec(i)),
    ])
```

- `get_timing_usec(i)` — time for the **last frame**. Jumps around.
- `get_average_timing_usec(i)` — an exponentially smoothed value. This is the one
  to put on an on-screen overlay: it is readable.
- `get_total_timing_usec()` — the per-frame sum.
- `was_system_executed(i)` — whether the system ran (disabled, or skipped via
  `requires_time`, returns `false`).
- `reset_profiling()` — zero everything.

The measurement is in **microseconds**, not milliseconds, on purpose: cheap
systems fit into single-digit microseconds, and a millisecond report would be all
zeros.

The measurement itself costs two timer calls per system per frame. If you need to
squeeze out the last bit:

```gdscript
scheduler.profiling_enabled = false
```

### An example of a real report

This is output from a game with 14 systems (600 frames, ~57 live entities):

```
  EnemySpawn                              0   avg      0
  SpatialIndex                          338   avg    336     ← 75% of the frame
  MissileSpatialIndex                     6   avg      6
  TurretTargeting                        41   avg     34
  ProjectileImpact                       54   avg     55
  EntityReaper                            1   avg      4
```

It is immediately clear where to look: `SpatialIndex` eats three quarters of the
frame. That is the point of the profiler — not to guess, but to see.

---

## 5.6. Access metadata

An optional description of what a system reads and writes. **It affects neither
the order nor the speed** — it is used by tooling.

```gdscript
func _init() -> void:
    system_name = "Movement"
    requires_time = true
    declare_read(TYPE_VELOCITY)
    declare_write(TYPE_POSITION)
    declare_structural_write(TYPE_SLEEPING)   # attach/detach of this type
    writes_world_structure = true             # create/destroy/reset
    complete_access_metadata()                # "the description is complete"
```

What for:

```gdscript
scheduler.validate_pipeline(world)      # are all types registered, do phases not run backwards
scheduler.systems_conflict(a, b)        # could these run in parallel
view.validate_owner_access()            # did the system declare what it reads through the View
```

`systems_conflict()` is a conservative dependency analysis. Until a system has
called `complete_access_metadata()`, its access is considered **unknown**, and it
conflicts with everything — so old code cannot accidentally end up in an unsafe
parallel batch.

`writes_world_structure = true` always conflicts with everything: creation and
destruction change the validity of raw ids and of every View.

> The current scheduler is **sequential**. The metadata is prepared ground, not
> working multithreading. Do not count on automatic parallelization.

---

## 5.7. Ready-made systems

### `EcsReaperSystem`

That same "one point of destruction":

```gdscript
var reaper := EcsReaperSystem.new(world)
scheduler.add_system(reaper)      # last

# after the frame:
reaper.last_reaped      # how many were destroyed this frame
reaper.total_reaped     # how many in total
```

`last_reaped` is handy for triggering a death sound or effect: it tells you how
many entities died without making you count them by hand.

### `EcsCapacityPolicySystem`

Automatic world growth — see
[section 7.3](07-time-events-capacity.md#73-capacity-and-growth-policy).

---

## Chapter summary

1. `setup()` — cache references; `execute()` — work; `teardown()` — in reverse
   order.
2. **Registration order is behaviour**, not formatting.
3. Pause is `delta == 0`; a system declares `requires_time = true` and the
   scheduler skips it on its own.
4. Phases are a filter and a label; no sorting ever happens.
5. Measurements accumulate between `begin_frame()`, so sub-steps sum up
   correctly.
6. Access metadata changes nothing in execution — it is for validation.
7. `EcsReaperSystem` — last, and exactly one.

---

[← Components](04-components-and-stores.md) | [Contents](README.md) | [Finding entities →](06-finding-entities.md)
