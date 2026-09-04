[← API reference](12-api-reference.md) | [Contents](README.md)

---

# 13. The inspector: how to look at a frame

---

## 13.1. The main idea

The most common way to look at performance is to print numbers on the screen and
watch them jump. This gives you almost nothing, and here is why.

At 240 frames per second, a number that updates every frame is **physically
impossible to read**. And the frame that is actually interesting — the one that
dipped and caused a hitch — is long gone by the time you shift your gaze to it.
You are looking at a random frame and drawing conclusions from it.

The inspector is built around the opposite approach: **collect every frame, and
show the distribution**.

| Question | Live numbers | Collected statistics |
|---|---|---|
| How much does a frame cost? | a flickering number | median, p95, max |
| Are there spikes? | occasionally something flashes | how many frames ran long and by how much |
| Who is to blame for the spikes? | **impossible to tell** | a ranked list with shares |
| What was in that frame? | it is already gone | a full breakdown, after the fact |

An example from a real game. A live overlay would show that `SpatialIndex` takes
75% of the frame — and that is true. But the collected statistics say something
different:

```
SpatialIndex      median 337 us, max 374   volatility x1.1   ← just expensive
TurretTargeting   median   3 us, max  44   volatility x14.7  ← here are the spikes
EntityReaper      median   1 us, max  25   volatility x25.0  ← and here
```

`SpatialIndex` is expensive **evenly**, so it does not cause spikes — it only
raises the baseline frame cost. The spikes are caused by two systems that are
almost always free and occasionally explode. A live overlay would have led the
optimization in the wrong direction.

---

## 13.2. Quick start

Two lines.

```gdscript
var _inspector: EcsInspector

func _ready() -> void:
    # ...build the world, stores, systems...
    _inspector = EcsInspector.attach(scheduler, world, {
        "mode": EcsInspector.Mode.DEV,
        "parent": $DebugLayer,          # remove it — and collection runs with no interface
    })

func _process(delta: float) -> void:
    scheduler.execute_all(delta)
    # ...presentation...
    _inspector.capture()                # as the LAST line of the frame
```

**Why `capture()` last.** It measures the wall-clock time between calls, so the
whole frame must fall in that interval, not just the scheduler. The difference
between the wall time and the sum of the systems is rendering, physics and
everything else outside ECS, and it is exactly what answers the question "whose
problem is this".

**Why the call is explicit, not automatic.** The `_process` order of nodes is
fragile: a panel added to the tree in the wrong place would collect data before
or after the moment you want. An explicit line goes where the frame is actually
finished, and that is visible in the code.

---

## 13.3. Modes: development vs release

Collection costs **5.7 µs per frame** (0.03% of a 16.6 ms frame) and does no
allocation. The interface costs two orders of magnitude more. So they are split.

```gdscript
EcsInspector.Mode.OFF         nothing runs
EcsInspector.Mode.TELEMETRY   collection + diagnostics, no interface
EcsInspector.Mode.INSPECTOR   + the panel, view only
EcsInspector.Mode.DEV         + controls that change the simulation
```

The typical choice:

```gdscript
"mode": EcsInspector.Mode.DEV if OS.is_debug_build() else EcsInspector.Mode.TELEMETRY
```

In release, `TELEMETRY` remains: the game draws nothing, but it can write a
report to a file on command or print diagnostics to the log. For a QA build this
is enough, and it costs a third of a percent of the frame.

### How to strip the interface from the build

The `inspector/` folder is deleted or excluded from the export preset — and
everything keeps working:

```gdscript
_inspector.has_panel()   # false, the rest of the API unchanged
```

This works because `EcsInspector` loads the panel **via `load()` by path**, not
by class name. If it referenced it by type, the excluded file would mean a script
parse error — and the whole game crashing. As it is, the missing file is just
`null`, and the mode quietly degrades to collection.

`debug/` (collection) stays: it is cheap and useful in release.

---

## 13.4. How to read the systems table

The panel's main screen is not the current frame but the distribution over the
window.

```
system                     median      p95      max   share  spread
SpatialIndex                  337      347      374   76.1%    1.1x
ProjectileImpact               54       61       73   11.4%    1.4x
TurretTargeting                 3       40       44    3.3%   14.7x
EntityReaper                    1       20       25    0.8%   25.0x
```

| Column | What it means |
|---|---|
| **median** | The typical cost. This number, not the mean: one OS stall drags the mean along, the median not |
| **p95** | What most frames stay under. This is what you compare against the budget |
| **max** | The worst case over the window |
| **share** | The fraction of all ECS time |
| **spread** | `max / median`. How uneven the system is |

**`spread` is the most important column, and it is in no ordinary overlay.** A
value near 1 means an even cost every frame: such a system raises the baseline but
causes no spikes. A large value means the system is usually free and occasionally
explodes — and that is exactly what feels like stutter.

---

## 13.5. Who makes the slow frames slow

The section everything was built for.

```
excess over each system's own median, across the slowest 12 frames

51.5%  TurretTargeting          ██████████
       median 3 us, peaks at 44 us (15x)
26.5%  EntityReaper             █████
       median 1 us, peaks at 25 us (25x)
 9.2%  ProjectileImpact         █
       median 54 us, peaks at 73 us (1x)
```

How this is computed:

1. The slow tail of the window is taken — frames above p95.
2. For each such frame, every system is attributed **how much it exceeded its own
   median**.
3. The totals are ranked.

The logic is simple: a system that is expensive **always** never exceeds its own
median, so it never appears in this list at all. Only the one that deviates from
its own norm appears — that is, exactly the spike culprit.

So `SpatialIndex`, with its 76% of frame time, is third here at 0%, while
`TurretTargeting`, with its 3.3%, is first at 51.5%.

---

## 13.6. Your game's counters

The library knows nothing about your enemies, your core or your projectiles. So
the application declares them:

```gdscript
_inspector.add_counter_section("Combat", func() -> Array:
    return [
        ["Enemies",     "%d / %d" % [context.hostiles.count, context.target_population]],
        ["Projectiles", context.projectiles.count],
        ["Core",        "%.0f%%" % (context.core_health / context.core_max_health * 100.0)],
    ])

_inspector.add_counter_section("Totals", func() -> Array:
    return [
        ["Killed",      context.kill_count],
        ["Intercepted", context.intercept_count],
        ["Shots fired", context.shots_fired],
    ])
```

One `Callable` that returns "label → value" pairs. It is called **at the panel's
redraw rate, not every frame**, so even an expensive computation inside it does
not touch the frame budget. Sections are shown in registration order.

Objects the world does not know about are registered the same way — the
diagnostics need them:

```gdscript
_inspector.register_grid("enemies", enemy_grid)
_inspector.register_query("targets", target_query)
_inspector.set_clock(simulation_clock)
```

---

## 13.7. Diagnostics

The panel does not just show numbers — it catches the documented pitfalls from
[chapter 10](10-common-mistakes.md) and explains what to do.

A real example from a game:

```
[WARNING] Grid: 'enemies' has far more cells than objects
    10125 cells for 60 entries - the rebuild is mostly iterating empty cells
    → Increase cell_size, or use UniformSpatialGrid.suggest_cell_size().

[WARNING] System: 'TurretTargeting' causes slow frames
    median 3 us but peaks at 44 us (15x); accounts for 52% of the excess
    → A system that is usually cheap and occasionally expensive is what
      stutter feels like.

[CRITICAL] Lifecycle: Destroy queue is not being drained
    up to 340 entities were still queued at the end of a frame
    → Register an EcsReaperSystem as the LAST system.
```

The first of these warnings explains why `SpatialIndex` takes 76% of the frame:
the grid rebuild costs `O(entries + CELLS)`, and there are 170 times more cells
than objects.

The full list of rules:

| Source | What it catches |
|---|---|
| World | Capacity exhausted or close to it |
| Store | A store is full; the change log overflowed |
| Frame | p95 over budget; uneven frame cost |
| System | A system dominates; a system makes frames slow |
| Lifecycle | The destroy queue is not being drained (the reaper is misplaced) |
| Query | The cache never hits; the result is truncated |
| Grid | Too many or too few cells; a 3D grid that is almost flat |
| Clock | Sub-steps are being dropped — the machine cannot keep up with `time_scale` |

The thresholds are configurable:

```gdscript
_inspector.diagnostics.frame_budget_usec = 8000.0    # 120 Hz
_inspector.diagnostics.volatility_warning = 3.0
```

---

## 13.8. Without an interface: console, file, CI

Everything above works headless. That is the same reason collection is separated
from rendering.

```gdscript
_inspector.print_report()        # a full report to the console
_inspector.print_worst_frame()   # a breakdown of the window's worst frame
_inspector.save_report("user://")# report.txt + report.json + frames.csv
```

The `log` and `save` buttons in the panel header do the same.

### A budget check in CI

```gdscript
extends SceneTree

func _init() -> void:
    var context := build_my_world()
    var inspector := EcsInspector.attach(context.scheduler, context.world,
        {"mode": EcsInspector.Mode.TELEMETRY})

    for frame in 600:
        context.scheduler.execute_all(1.0 / 60.0)
        inspector.capture()

    inspector.refresh_now()
    print(EcsReport.to_text(inspector.recorder, inspector.stats, context.world,
        inspector.get_findings()))

    var p95: float = inspector.stats.get_frame_p95_usec()
    if p95 > 8000.0:
        push_error("ECS p95 %.2f ms exceeds the 8 ms budget" % (p95 / 1000.0))
        quit(1)
    quit(0)
```

Now a performance regression fails the build the same way a broken test does.
Comparing `report.json` between builds shows which system exactly got more
expensive.

### A bug report from a tester

The `save` button drops three files into `user://`. `ecs_report.txt` goes into a
ticket as-is; `ecs_frames.csv` is one row per frame and one column per system,
and opens in any spreadsheet.

---

## 13.9. The panel

Sections collapse with a click on the header; the panel itself collapses with the
"−" button in the header, leaving the title on screen. Below 430 pixels wide the
layout becomes a single narrow column — for a portrait mobile screen.

| Section | Contents |
|---|---|
| **Frame** | One "now" line, then median / p95 / max over the window |
| **Counters** | Your counters (13.6) |
| **Systems** | The distribution table (13.4) |
| **What makes the slow frames slow** | Spike attribution (13.5) |
| **Diagnostics** | Findings (13.7) |
| **Worst frame** | A full breakdown of the window's worst frame |
| **World and stores** | Population, stores, grids, clock |

### Disabling systems on the fly

In `DEV` mode, the system names in the table are clickable. Click — the system is
disabled; click again — it is enabled.

This is the fastest way to find out what a system is actually responsible for:
disable `EnemySteering` and the enemies stop turning, so it is that one. And the
fastest way to localize a bug: disable half the pipeline and see whether the
symptom disappears.

> Disabling changes the simulation, so it is available only in `DEV` mode.

---

## 13.10. What it costs

Measured on 20 systems (`tests/benchmark_ecs.gd`):

| Operation | Rate | Cost | Fraction of a 16.6 ms frame |
|---|---|---|---|
| `recorder.capture()` | every frame | 5.7 µs | **0.035%** |
| `stats.analyse()` | 2 Hz | 906 µs | 0.18% |
| `diagnostics.inspect()` | 0.5 Hz | 9.9 µs | negligible |
| Window memory (240 frames) | — | 30.5 KB | — |

**Collection runs every frame, rendering does not.** No frame is lost, but the
aggregates are recomputed a few times a second, and the panel is drawn 6 times a
second. A median over 240 frames does not visibly change over a tenth of a second
anyway, and updating `Control` nodes costs an order of magnitude more than
collection itself.

The rates are configurable:

```gdscript
_inspector.stats_refresh_hz = 1.0
_inspector.diagnostics_refresh_hz = 0.25
```

---

## 13.11. Restarting a level

After `world.reset()`, the frames of the previous run distort the medians and the
attribution:

```gdscript
func _on_restart_requested() -> void:
    restart_simulation()
    _inspector.recorder.clear()
    _inspector.diagnostics.reset()
```

---

## Chapter summary

1. **Collected statistics are more informative than live numbers.** The frame
   that hitched is already gone by the time you look at it.
2. `median` and `p95` instead of the mean; **`spread` (max/median) shows who
   causes spikes**.
3. **Attribution** names the culprit: a system that is expensive always is not to
   blame for spikes.
4. Collection costs 0.035% of a frame and allocates nothing — no reason not to
   leave it in release.
5. The interface is stripped from the export with no code change.
6. Game counters are one `Callable`, called at the redraw rate.
7. Everything works headless: a report to the console, to a file, a budget check
   in CI.

---

[← API reference](12-api-reference.md) | [Contents](README.md)
