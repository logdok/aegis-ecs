[← Introduction to ECS](01-intro-to-ecs.md) | [Contents](README.md) | [World and entities →](03-world-entities-lifecycle.md)

---

# 2. Quick start

---

## 2.1. Installation

1. Copy the `addons/aegis_ecs/` folder into your project.
2. Done.

You do **not** need to enable the plugin in "Project → Project Settings →
Plugins". All classes are declared with `class_name`, and Godot registers such
classes globally simply because the file is present in the project. The entry in
the plugin list exists only so the add-on is visible and has a version.

To verify everything landed:

```bash
godot --headless --script res://addons/aegis_ecs/example/minimal_example.gd
```

It should finish with the line `RESULT: OK`.

### About name conflicts

The add-on claims these global names:

`EcsWorld`, `EcsComponentStore`, `EcsPackedStore`, `EcsTagStore`, `EcsView`,
`EcsQuery`, `EcsSystem`, `EcsScheduler`, `EcsReaperSystem`,
`EcsCapacityPolicySystem`, `SimulationClock`, `UniformSpatialGrid`, `AngleMath`.

If one of them is already taken in your project, Godot reports an error — rename
the `class_name` in the corresponding add-on file. None of these names are used
as a string anywhere inside the library, so renaming is safe.

### What you can delete

The modules are independent; drop what you do not need:

| Folder | What's inside | Depends on |
|---|---|---|
| `ecs/` | Core: world, stores, systems, scheduler | nothing |
| `spatial/` | `UniformSpatialGrid` — neighbour search | nothing |
| `time/` | `SimulationClock` — fixed step and time scale | nothing |
| `math/` | `AngleMath` — angle turning | nothing |
| `example/`, `tests/` | The example and self-checks | everything above |

---

## 2.2. A full working example

Here is a simulation in its entirety. 500 particles fly out from the centre;
those that cross a boundary are destroyed. This works as-is — copy it into a
file and run it.

```gdscript
extends SceneTree

# --- 1. The component store -------------------------------------------------
# Declare the fields and name them once. Memory allocation, growth and
# relocation of data on removal are handled by the library.

class Particles extends EcsPackedStore:
    var x: PackedFloat32Array = PackedFloat32Array()
    var y: PackedFloat32Array = PackedFloat32Array()
    var vx: PackedFloat32Array = PackedFloat32Array()
    var vy: PackedFloat32Array = PackedFloat32Array()

    func _init() -> void:
        track(&"x", &"y", &"vx", &"vy")


# --- 2. The context --------------------------------------------------------
# The library knows nothing about your game: it simply passes this object
# to every system. Keep references to stores and shared state here.

class Context:
    var world: EcsWorld
    var particles: Particles
    var escaped: int = 0


# --- 3. Systems ----------------------------------------------------------

class MovementSystem extends EcsSystem:
    var _context: Context

    func _init() -> void:
        system_name = "Movement"
        requires_time = true          # do not run while paused

    func setup(_world: EcsWorld, context) -> void:
        _context = context

    func execute(delta: float) -> void:
        var p: Particles = _context.particles
        # Local aliases: touching a local variable in the loop is
        # noticeably cheaper than re-reading an object field each time.
        var x: PackedFloat32Array = p.x
        var y: PackedFloat32Array = p.y
        var vx: PackedFloat32Array = p.vx
        var vy: PackedFloat32Array = p.vy
        for slot in p.count:
            x[slot] += vx[slot] * delta
            y[slot] += vy[slot] * delta


class BoundsSystem extends EcsSystem:
    var _context: Context

    func _init() -> void:
        system_name = "Bounds"
        requires_time = true

    func setup(_world: EcsWorld, context) -> void:
        _context = context

    func execute(_delta: float) -> void:
        var p: Particles = _context.particles
        var x: PackedFloat32Array = p.x
        var owners: PackedInt32Array = p.dense_entities
        for slot in p.count:
            if absf(x[slot]) > 100.0:
                # Only marks. The entity lives until the end of the frame,
                # so the iteration will not fall apart mid-flight.
                _context.world.queue_destroy(owners[slot])
                _context.escaped += 1


# --- 4. Assembly and run -----------------------------------------------

const TYPE_PARTICLE: int = 0

func _init() -> void:
    var context := Context.new()
    context.world = EcsWorld.new(1000)          # initial capacity

    context.particles = Particles.new()
    context.world.register_store(context.particles, TYPE_PARTICLE)

    # Registration order = execution order = behaviour.
    var scheduler := EcsScheduler.new()
    scheduler.add_system(MovementSystem.new())
    scheduler.add_system(BoundsSystem.new())
    scheduler.add_system(EcsReaperSystem.new(context.world))   # always last
    scheduler.setup_all(context.world, context)

    # Batched creation: one call instead of 500.
    var ids := PackedInt32Array()
    ids.resize(500)
    var spawned: int = context.world.create_entities(500, ids)

    var first_slot: int = context.particles.count
    context.particles.attach_many(ids, spawned)

    var rng := RandomNumberGenerator.new()
    rng.seed = 12345
    for i in spawned:
        var slot: int = first_slot + i
        context.particles.x[slot] = 0.0
        context.particles.y[slot] = 0.0
        context.particles.vx[slot] = rng.randf_range(-40.0, 40.0)
        context.particles.vy[slot] = rng.randf_range(-40.0, 40.0)

    for frame in 600:
        scheduler.execute_all(1.0 / 60.0)

    print("remaining: %d, escaped: %d"
        % [context.world.get_live_count(), context.escaped])
    quit(0)
```

Run:

```bash
godot --headless --script res://your_file.gd
```

---

## 2.3. Walk-through: what just happened

### Step 1 — the store

```gdscript
class Particles extends EcsPackedStore:
    var x: PackedFloat32Array = PackedFloat32Array()
    ...
    func _init() -> void:
        track(&"x", &"y", &"vx", &"vy")
```

`EcsPackedStore` is the recommended base for ordinary data stores. You declare
typed fields and list their names. Everything else — allocating memory for the
world's capacity, growth, relocating data on swap-remove — is done for you.

The fields stay ordinary typed members, so in the hot loop you read `p.x`
directly, at full speed. **There is no fee for the convenience.**

> There is a lower level too — `EcsComponentStore`, where these operations are
> written by hand. You need it for exotic layouts; for ordinary data use
> `EcsPackedStore`. Details in [chapter 4](04-components-and-stores.md).

### Step 2 — the context

The library **knows nothing about your game**. It passes systems the `context`
object as-is, and that is where you keep references to stores.

This is deliberate: it is what lets the add-on move between projects with no
edits.

### Step 3 — systems

Three things worth noticing:

1. **`system_name`** is set in `_init()` — it shows up in profiling.
2. **`requires_time = true`** means "do not run me when time is stopped". Pause
   in this library is a zero step, not a skipped frame, so rendering and the HUD
   keep working.
3. **Local array aliases** before the loop. In Godot 4, `Packed*Array` is passed
   **by reference**, so writes through the alias land in the store immediately —
   there is nothing to assign back.

### Step 4 — assembly

```gdscript
scheduler.add_system(MovementSystem.new())
scheduler.add_system(BoundsSystem.new())
scheduler.add_system(EcsReaperSystem.new(context.world))
```

`EcsReaperSystem` is that same "one point of destruction" from
[section 1.7](01-intro-to-ecs.md#17-why-destruction-is-deferred), wrapped as a
ready-made class. **Put it last and exactly once** in the pipeline.

### Batched creation

```gdscript
var spawned: int = context.world.create_entities(500, ids)
var first_slot: int = context.particles.count
context.particles.attach_many(ids, spawned)
```

`create_entities()` and `attach_many()` do in one call what would otherwise take
500. In measurements this is **2.4x faster** than per-element spawning.

The slots of the newly attached components are contiguous, starting at the
`count` value taken **before** the call — so you can write the data right away at
index `first_slot + i`.

---

## 2.4. A frame in a real game

In the example above the frame spins in a `for` loop. In a real game it looks
like this:

```gdscript
extends Node3D

var _context: Context
var _scheduler: EcsScheduler

func _ready() -> void:
    # ...build the world, as in the example...
    pass

func _process(delta: float) -> void:
    var step: float = 0.0 if _paused else minf(delta, 0.1)
    _scheduler.execute_all(step)
```

Two notes:

- **Pause is `0.0`, not a skipped call.** The scheduler skips systems with
  `requires_time = true` on its own, while rendering and the camera keep going.
- **`minf(delta, 0.1)`** clamps the step: if the game froze for a second,
  without this clamp every object teleports. For a serious simulation take
  `SimulationClock` instead — see [chapter 7](07-time-events-capacity.md).

---

## 2.5. Where to go next

- Unclear why an entity is a number, and what a handle is →
  [chapter 3](03-world-entities-lifecycle.md)
- You need a store with more complex data, or with a `Resource` inside →
  [chapter 4](04-components-and-stores.md)
- You need to process not all entities but only those with a certain set of
  components → [chapter 6](06-finding-entities.md)
- You need to speed time up or slow it down without desync →
  [chapter 7](07-time-events-capacity.md)
- You need to search for neighbours ("who is nearby") →
  [chapter 8](08-spatial-search.md)

---

[← Introduction to ECS](01-intro-to-ecs.md) | [Contents](README.md) | [World and entities →](03-world-entities-lifecycle.md)
