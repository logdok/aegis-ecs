[← Finding entities](06-finding-entities.md) | [Contents](README.md) | [Spatial search →](08-spatial-search.md)

---

# 7. Time, events, capacity

Three tools that cover typical simulation needs: a controlled time rate, a
reaction to entities appearing and disappearing, and world growth for an
unpredictable population.

---

## 7.1. SimulationClock — fixed step and time scale

### The problem

Passing the frame's raw `delta` straight into the simulation is fine only as long
as that delta is small. The moment the player can **speed time up**, everything
breaks: at a scale of 50×, a 16 ms frame turns into an 800 ms step.

And then anything that advances by a threshold **jumps over** several thresholds
in a single update:

- a cell that divides at age 10, in one step lives through age 0 → 12 and divides
  once instead of twice;
- a projectile "teleports" through its target, because a point hit test does not
  see the intermediate positions;
- a 0.2 s cooldown fires once instead of four times.

The simulation does not just run faster — it **produces a different result**. And
on a slower machine, a different one again, because delta is larger there.

### The solution

`SimulationClock` accumulates real time, multiplies it by the scale and reports
how many **identical** fixed-size segments fit into it.

```gdscript
var clock := SimulationClock.new()
clock.fixed_step = 1.0 / 60.0     # the length of one simulation segment
clock.time_scale = 4.0            # speed-up
clock.max_substeps = 8            # safety valve
```

### Using it with phases (recommended)

```gdscript
func _process(delta: float) -> void:
    var steps: int = clock.advance(delta)

    scheduler.begin_frame()
    for i in steps:
        scheduler.execute_phase(PHASE_SIMULATION, clock.fixed_step)
    # Presentation — exactly once per frame, with the REAL delta.
    scheduler.execute_phase(PHASE_PRESENTATION, delta)
```

**Notice the two different deltas.** The simulation gets `fixed_step`,
presentation gets the frame's real time. Running the whole pipeline through the
sub-step loop would mean doing the rendering work N times per frame for no
benefit.

When `steps == 0` (pause, or less than one segment accumulated), the presentation
phase still runs — that is exactly what keeps the game drawn.

### Using it without phases

```gdscript
var steps: int = clock.advance(delta)
if steps == 0:
    scheduler.execute_all(0.0)          # only systems without requires_time
else:
    for i in steps:
        scheduler.execute_all(clock.fixed_step)
```

### The safety valve against the "death spiral"

`max_substeps` is not just a limit. It is protection against a known pathology:
if one frame was slow, more time accumulated in the accumulator; running all the
accumulated time makes the frame even slower, which accumulates even more — and
the game hangs forever.

Beyond `max_substeps` the surplus is **dropped**: the simulation briefly runs in
slow motion instead of locking up.

```gdscript
clock.dropped_substeps     # how many segments were dropped in total
clock.is_saturated()       # is it hitting the limit right now
```

A constantly growing `dropped_substeps` means the machine cannot keep up with the
requested `time_scale`. This is an honest signal, not an error.

### Interpolation

If the simulation rate is lower than the frame rate, movement looks steppy.
`get_alpha()` returns the fraction of the unspent segment in `[0, 1)`:

```gdscript
var alpha: float = clock.get_alpha()
var drawn_position: Vector3 = previous_position.lerp(current_position, alpha)
```

### The full API

```gdscript
clock.advance(real_delta) -> int    # call EXACTLY once per frame
clock.fixed_step                    # the segment length
clock.time_scale                    # 0 = stop, 1 = real time, 50 = fast
clock.max_substeps                  # safety valve
clock.paused                        # freeze without losing the accumulator
clock.get_last_substeps()
clock.get_alpha()
clock.is_saturated()
clock.get_effective_time_scale(real_delta)   # actual vs requested rate
clock.elapsed_simulated             # the exact sum, with no drift
clock.total_substeps
clock.dropped_substeps
clock.reset()                       # on a level restart
```

> `elapsed_simulated` grows by exactly `fixed_step` per segment, so it is
> **exact**, unlike the sum of fractional deltas, which accumulates error.

---

## 7.2. The change log — reacting to birth and death

The library deliberately has no "component added / removed" events: signals in
the hot loop at tens of thousands of entities would cost more than the work
itself.

Instead there is a **structural change log**, enabled on a specific store.

```gdscript
enemies.track_changes = true
```

While the flag is off (the default), it costs **one check per structural
operation**, that is, effectively nothing.

### Reading the log

```gdscript
class DeathEffectSystem extends EcsSystem:
    var _context: Context

    func _init() -> void:
        system_name = "DeathEffects"

    func setup(_world: EcsWorld, context) -> void:
        _context = context

    func execute(_delta: float) -> void:
        var enemies: EnemyStore = _context.enemies

        for i in enemies.added_count:
            var entity: int = enemies.added_entities[i]
            _spawn_appear_effect(entity)

        for i in enemies.removed_count:
            var entity: int = enemies.removed_entities[i]
            _spawn_death_effect(entity)

        _context.world.clear_change_logs()
```

### Where to put the reader system

**Right after `EcsReaperSystem`.** At that point:

- `added_entities` holds everything that appeared this frame;
- `removed_entities` holds everything that died this frame (the reaper has
  already run).

```gdscript
scheduler.add_system(SpawnSystem.new())
scheduler.add_system(CombatSystem.new())
scheduler.add_system(EcsReaperSystem.new(world))
scheduler.add_system(DeathEffectSystem.new())     # ← reads the log and clears it
```

### Rules

- The valid prefixes are `[0, added_count)` and `[0, removed_count)`. The arrays
  themselves are larger; the rest is garbage.
- **The order is undefined.** Do not rely on it.
- An entity created and destroyed in the same frame lands in **both** logs. This
  is correct.
- `clear()` and `world.reset()` **do not write** individual removals — they raise
  the `change_log_overflowed` flag. Running the whole population through the log
  on a level restart is not what the calling code wants.
- `world.clear_change_logs()` clears the logs of every store that has them
  enabled.

### Cost

Enabling it allocates two buffers that grow by doubling until they reach the size
of typical per-frame churn. After that — constant memory and one array write per
structural operation.

---

## 7.3. Capacity and growth policy

### Explicit growth

```gdscript
if world.reserve_capacity(200_000):
    _resize_my_render_buffers(200_000)
```

The world and **all** registered stores grow together; existing raw ids, handles
and dense slots stay valid.

This is an **allocating barrier**. Call it on a loading screen or at an explicit
phase boundary — never in the middle of a system iteration.

If at least one store does not support growth (has no `_grow_dense`), the method
returns `false` **without changing anything**. `EcsPackedStore` and `EcsTagStore`
support it always.

> The library can grow only its **own** buffers. Everything your game allocated
> alongside — `MultiMesh`, physics batches, network arrays — is your
> responsibility.

### The automatic policy

For a simulation with explosive population growth — cell division, a chain
reaction, waves — waiting for `create_entity() == -1` is too late: spawns have
already started being lost.

```gdscript
var policy := EcsCapacityPolicySystem.new(world)
policy.grow_threshold = 0.8          # grow at 80% fill
policy.growth_factor = 1.5           # new capacity = old × 1.5
policy.maximum_capacity = 500_000    # ceiling; 0 = no limit
policy.check_interval_frames = 30
policy.on_capacity_grown = _on_world_grown

scheduler.add_system(EcsReaperSystem.new(world))
scheduler.add_system(policy)          # ← RIGHT after the reaper
```

```gdscript
func _on_world_grown(previous: int, next: int) -> void:
    _render_buffer.resize(next)
    print("world grew: %d → %d" % [previous, next])
```

**Register it right after the reaper** or at another explicit phase boundary:
growth reallocates all buffers, so no system may be holding a dense slot or an
array alias across that call.

A forced check, if you know a spike is coming:

```gdscript
policy.grow_now()
```

Diagnostics: `policy.growth_count`, `policy.last_growth_capacity`.

### How much capacity to take upfront

Memory per entity is roughly:

- **the world:** ~23 bytes of bookkeeping per entity;
- **each store:** 8 bytes (sparse + dense) plus the payload size.

For 100,000 entities and 10 stores with a 16-byte payload each, this is about
`100k × (23 + 10 × 24) ≈ 26 MB`. Allocating more than you need upfront is almost
always cheaper than growing during play.

---

## Chapter summary

1. `SimulationClock` makes the simulation **reproducible** at any time rate; raw
   delta does not.
2. The simulation gets `fixed_step`, presentation gets the real `delta`.
3. `max_substeps` is the safety valve against the death spiral; dropped segments
   are visible.
4. The change log (`track_changes`) is your "birth and death events"; the reader
   goes right after the reaper and clears the log itself.
5. `reserve_capacity()` is an allocating barrier; only at a safe boundary.
6. `EcsCapacityPolicySystem` grows **ahead of time**, not after spawns are lost.

---

[← Finding entities](06-finding-entities.md) | [Contents](README.md) | [Spatial search →](08-spatial-search.md)
