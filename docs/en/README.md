# Aegis ECS — user guide

Aegis ECS is a compact **ECS engine in pure GDScript** for Godot 4.4+. It is
built for simulations where thousands to tens of thousands of objects update
every frame: units, projectiles, gameplay particles, crowds, bullet hell,
population simulations.

- **No dependencies.** No GDExtension, no C#, no third-party add-ons.
- **No hidden allocations** in the steady-state frame loop. Memory grows only
  through an explicit barrier.
- **No node per game object.** Data lives in `Packed*Array`.
- **No boilerplate.** `EcsPackedStore` generates the entire store wiring.
- **Batched structural operations.** Spawn and destroy are one call, not N.
- **Built-in inspector.** Frame statistics, spike-culprit attribution and
  diagnostics for common mistakes — wired in with a single line.
- **Safe references.** Packed generational handles guard against ABA.
- **Exports anywhere**, iOS included, with no native dependencies.

---

## How to read this guide

The chapters are ordered so you can read them front to back, but each one stands
on its own.

**If you have never heard of ECS** — start with chapter 1. It explains not "how
to call this library's methods" but **why** the approach exists at all and which
problem it solves. It is the most important chapter: without it, the rest will
look like a strange way to write ordinary code.

**If you have worked with ECS before** (Unity DOTS, EnTT, flecs, bevy) — jump
straight to chapter 2, then to chapter 4: stores here are built as a sparse set,
and that is where all the specifics of this implementation live.

**If you are in a hurry** — chapter 2 has a fully working 40-line example.

| # | Chapter | About |
|---|---|---|
| 1 | [Introduction to ECS](01-intro-to-ecs.md) | What ECS is, which problem it solves, when you need it and when it is harmful |
| 2 | [Quick start](02-quick-start.md) | Installation and a first working world in 40 lines |
| 3 | [World, entities, lifecycle](03-world-entities-lifecycle.md) | Entity as a number, the handle, deferred destruction |
| 4 | [Components and stores](04-components-and-stores.md) | Sparse set, `EcsPackedStore`, hand-written stores, resource ownership |
| 5 | [Systems and the scheduler](05-systems-and-scheduler.md) | Order as a contract, phases, pause, profiling |
| 6 | [Finding the entities you want](06-finding-entities.md) | Direct loop, `EcsView`, `EcsQuery` — and how to choose |
| 7 | [Time, events, capacity](07-time-events-capacity.md) | `SimulationClock`, the change log, the growth policy |
| 8 | [Spatial search](08-spatial-search.md) | `UniformSpatialGrid`, picking the cell size, `AngleMath` |
| 9 | [Performance](09-performance.md) | The GDScript cost model, measurements, how not to optimize blind |
| 10 | [Common mistakes](10-common-mistakes.md) | Symptom → cause → fix |
| 11 | [Full example](11-full-example.md) | A working mini-simulation from start to finish |
| 12 | [API reference](12-api-reference.md) | Every class and method in tables |
| 13 | [Inspector](13-inspector.md) | The debug panel: collected frame statistics, spike attribution, diagnostics |

### Additional

| Document | About |
|---|---|
| [Architecture](ARCHITECTURE.md) | A decision reference: handle bit layout, hook auto-detection, the batched destruction design, capacity growth |

---

## Six safety rules

A short reminder. Each rule is expanded in its own chapter, and the symptoms of
breaking them are collected in [chapter 10](10-common-mistakes.md).

1. **A raw id is for the hot loop; a handle is for references across frames.** A
   runtime handle must not be written into save/network data as a stable
   identifier.
2. **Structural changes happen only at sync points.** Not in the middle of a
   system; you cannot cache a dense slot across that boundary.
3. **Implement `_relocate_dense()`** in a hand-written store — a forgotten field
   silently mixes data up. Or use `EcsPackedStore`, where you cannot get it
   wrong.
4. **`Packed*Array` in Godot 4 is reference semantics.** A local alias taken
   before the loop keeps your writes without any assignment back.
5. **View/Query refresh before a structural change**, and a store's membership
   cannot be changed in the middle of iterating that same store.
6. **Pause is `delta == 0`**, not a skipped frame. Declare `requires_time`.

---

## Verifying it works

The add-on ships with four self-checks. Run them from the root of a project that
contains the add-on:

```bash
godot --headless --script res://addons/aegis_ecs/example/minimal_example.gd
godot --headless --script res://addons/aegis_ecs/tests/test_advanced_ecs.gd
godot --headless --script res://addons/aegis_ecs/tests/test_ecs_features.gd
godot --headless --script res://addons/aegis_ecs/tests/test_inspector.gd
```

Each one must finish with the line `RESULT: OK` and exit code 0. They are usable
in CI as-is.

Performance measurements on your machine:

```bash
godot --headless --script res://addons/aegis_ecs/tests/benchmark_ecs.gd
```

The full working simulation, dissected in [chapter 11](11-full-example.md):

```bash
godot --headless --script res://addons/aegis_ecs/example/colony_example.gd
```

---

## What you can delete

The modules are independent; drop what you do not need:

| Folder | What's inside | Depends on |
|---|---|---|
| `ecs/` | Core: world, stores, systems, scheduler, ready-made systems | nothing |
| `spatial/` | `UniformSpatialGrid` — neighbour search | nothing |
| `time/` | `SimulationClock` — fixed step and time scale | nothing |
| `math/` | `AngleMath` — angle turning | nothing |
| `debug/` | Frame statistics collection, diagnostics, reports. No nodes | `ecs/` |
| `inspector/` | The visual panel. Stripped from the export | `debug/` |
| `example/`, `tests/` | Examples and self-checks | everything above |

### About name conflicts

The add-on claims the global names `EcsWorld`, `EcsComponentStore`,
`EcsPackedStore`, `EcsTagStore`, `EcsView`, `EcsQuery`, `EcsSystem`,
`EcsScheduler`, `EcsReaperSystem`, `EcsCapacityPolicySystem`, `SimulationClock`,
`UniformSpatialGrid`, `AngleMath`, and from the debug part — `EcsInspector`,
`EcsFrameRecorder`, `EcsFrameStats`, `EcsDiagnostics`, `EcsReport`.

If one of them is already taken, Godot reports an error — rename the `class_name`
in the corresponding add-on file. None of these names are used as a string
anywhere inside the library, so renaming is safe.

---

## Glossary

Terms that show up across all the chapters.

| Term | Meaning |
|---|---|
| **Entity** | Just an integer — an identifier. Not an object, not a node, not a class. |
| **Component** | Pure data attached to an entity. Position, health, velocity. |
| **System** | Pure logic that reads and writes components. No state of its own. |
| **World** | The allocator of entity identifiers and the registry of stores. |
| **Store** | A container for one component type's data across all entities. |
| **Dense slot** | An index inside a store's dense array. Not equal to the entity id. |
| **Sparse set** | A two-array structure that gives both dense iteration and O(1) lookup. |
| **Swap-remove** | O(1) removal: the last element moves into the removed one's place. |
| **Structural change** | A change of membership: create, destroy, attach, detach. |
| **Handle** | A safe reference to an entity that survives across frames. |
| **Broadphase** | A structure for answering "who is nearby" quickly. |

---

## License and compatibility

- **Godot 4.4+.** Verified on 4.4, 4.6 and 4.7.1.
- **Export:** no restrictions. Pure GDScript builds for every platform.
- **License:** MIT — see [LICENSE](../../LICENSE). Copyright (c) 2026 Vitalii
  Yurchenko.
