[← Contents](README.md) | Next chapter: [Quick start →](02-quick-start.md)

---

# 1. Introduction to ECS

This chapter is not about Aegis. It is about the **approach** that Aegis
implements. If you are an experienced programmer but have never heard the
acronym ECS, that is normal: it barely shows up outside game development and
simulation, even though the idea itself is old and not tied to games.

There is not a single API call here. Only **why** everything that follows is
built the way it is.

---

## 1.1. The problem it all starts with

Picture an ordinary game. It has 10,000 enemies. Each has a position, a
velocity, health, and every frame each one must do three things: move, check
whether a projectile hit it, and draw.

The most natural way to write this is the one we were all taught:

```gdscript
class Enemy extends Node3D:
    var health: float
    var speed: float

    func _process(delta):
        position += transform.basis.z * speed * delta
```

Create 10,000 of these nodes, add them to the scene, and Godot calls `_process`
on each. The code reads beautifully. It works. With hundreds of enemies — great.

With ten thousand it does not work. And to understand why, you have to look not
at the code but at **memory**.

---

## 1.2. Why it is slow: a story about the cache

The processor does not read memory one byte at a time. It reads **cache lines** —
blocks of about 64 bytes. When you ask for one `float`, the processor pulls in
the 64 bytes around it, hoping you will ask for a neighbour next.

This is the single most important assumption in all modern processor
architecture, and it is called **locality of reference**. A read from the L1
cache is roughly 1 cycle. A read from main memory, if it is not in the cache, is
100 to 300 cycles. That is a difference of **hundreds of times**.

Now look at how our `Enemy` is laid out in memory:

```
Enemy #1  [ Node3D: transform, parent, children, name, groups, signals... ] [health] [speed]
Enemy #2  [ Node3D: transform, parent, children, name, groups, signals... ] [health] [speed]
```

Each `Enemy` is a separate heap object, hundreds of bytes in size, and they are
scattered across memory arbitrarily: between them sit other objects, created and
destroyed at different times.

When the movement loop reads `speed` on enemy #1, the processor pulls in the 64
bytes around that field. What is in them? Part of the internal state of `Node3D`:
pointers to the parent node, the child list, the name, the group mask. **None of
that is needed by the movement loop.** The next step, the loop goes to enemy #2,
which sits somewhere else — and the processor again pulls in 64 bytes, of which 4
are useful.

Result: to read 10,000 `speed` values of 4 bytes each (40 KB of useful data),
the processor drags hundreds of kilobytes across the bus, almost all of it
wasted. And that is not the only problem: `_process` on each node is a **virtual
call** through the scene tree, and there are 10,000 of those per frame.

---

## 1.3. The idea that changes everything: lay the data out differently

The question data-oriented design asks is: what if the data were laid out the
way the loop reads it?

The movement loop needs **all positions** and **all velocities**. Not "all of
object #1, then all of object #2", but "all positions in a row".

```
positions_x [ 0.0, 1.5, 3.2, 7.1, ... ]   ← 10,000 numbers in a row
positions_z [ 0.0, 4.2, 1.1, 9.8, ... ]
speeds      [ 2.0, 2.5, 1.8, 3.0, ... ]
```

This is called **SoA — structure of arrays**, as opposed to the usual **AoS —
array of structures**.

Now the movement loop reads three dense arrays in sequence. Each 64-byte cache
line holds **16 useful values** instead of one. The processor sees linear access
and starts prefetching the next blocks ahead of time (hardware prefetch). No
virtual calls: it is a plain `for i in count`.

The same amount of work, the same math — but the data is prepared the way the
hardware consumes it. In our measurements (chapter 9), iterating 10,000 elements
of two joined arrays takes **0.57 ms**, about 57 nanoseconds per element,
including the lookup of the second component.

> **The main point.** ECS is not "an architectural pattern for the sake of clean
> code". It is first and foremost a way to lay out data in memory so the
> processor can read it fast. Everything else is a consequence of that decision.

---

## 1.4. The second problem: inheritance does not scale

There is a separate reason too, unrelated to performance.

Let's start writing a class hierarchy for a game:

```
Entity
├── Character
│   ├── Player
│   └── Enemy
│       ├── FlyingEnemy
│       └── GroundEnemy
└── Projectile
```

Now the client says: "make a flying enemy that also explodes, like a
projectile". Where does it go? It does not fit into `FlyingEnemy` (that one
cannot explode), nor into `Projectile` (that one has no health). The classic
escape is to pull "explodability" up into the base `Entity`, and now **the
player has an `explosion_radius` field too**, one that is never used.

Six months later `Entity` has 60 fields, of which each concrete type uses 8.
This is a well-known dead end; in the literature it is called the **diamond
problem** or the **tyranny of the dominant decomposition**: a hierarchy forces
you to pick ONE axis of classification, while real objects are classified along
many at once.

ECS solves this radically: **there is no hierarchy at all**. An object is not a
type but a **set of components**. A flying exploding enemy is an entity that has
`Position`, `Velocity`, `Health`, `Flying` and `Explosive`. You do not write a
class for it; it is just another combination of the same building blocks.

This is what the literature calls **composition over inheritance**, taken to its
logical conclusion.

---

## 1.5. Three letters

Now we can name the parts.

### E — Entity

**An entity is just a number.** Not an object, not a class, not a node. An
identifier.

```gdscript
var entity: int = world.create_entity()   # for example, 42
```

An entity has neither data nor methods. It is a **key** by which data is looked
up in stores. That is exactly why there can be tens of thousands of them: each
costs a few bytes of bookkeeping, not hundreds of bytes of an object.

### C — Component

**A component is pure data with no behaviour.**

```gdscript
# Not a class with methods, just parallel arrays of numbers:
positions.x[slot]     # 12.5
positions.y[slot]     # 0.0
health.current[slot]  # 87.0
```

A component has no methods because it does nothing. It is **what** is known
about an entity.

Importantly, components are **optional and independent**. One entity has a
position and health, another has a position and velocity, a third has only an
"enemy" tag. The combination is arbitrary and can change during play: add a
`Stunned` component and the entity starts being processed by other systems;
remove it and it stops.

### S — System

**A system is pure logic with no state of its own.**

```gdscript
class MovementSystem extends EcsSystem:
    func execute(delta: float) -> void:
        # read velocities, write positions
```

A system does not keep "a list of its enemies" — it re-iterates the stores from
scratch every frame. It does not know about other systems. It is a "what to do
with this data" function wrapped in a class.

Systems communicate **only through data**. The shooting system does not call the
health system; it writes damage into a component, and the health system reads it
later. This removes the worst property of large codebases — the web of direct
calls between subsystems.

---

## 1.6. Sparse set: how to find a component by entity

One question remains, and it is the most interesting.

We want the data to be laid out **densely** (for fast iteration). But entities
are created and die in arbitrary order, and not every one has every component. If
you just make an array indexed by entity id, it will be **full of holes**: 10,000
slots, of which 300 are occupied. Iterating such an array is 9,700 wasted checks.

The solution is a structure called a **sparse set**. It is two arrays working in
opposite directions:

```
sparse_index[entity_id] → dense slot, or -1 if there is no component
dense_entities[slot]    → which entity this slot belongs to
```

Plus the data arrays themselves, indexed by **the same dense slot**.

Example. Entities 42, 7 and 100 have the component:

```
sparse_index:   [.. -1 .. 1 (at id 7) .. 0 (at id 42) .. 2 (at id 100) .. ]
dense_entities: [ 42, 7, 100 ]
positions_x:    [ 12.5, 3.0, 88.1 ]
                    ↑     ↑     ↑
                 slot 0  slot 1  slot 2
```

What this gives you:

1. **Iteration is dense.** `for slot in count` walks exactly three elements, with
   no "is there anything here" check.
2. **Lookup is O(1).** "Does entity 42 have the component?" is one read of
   `sparse_index[42]`.
3. **Removal is O(1)** thanks to **swap-remove**: to remove an element from the
   middle of the dense array without leaving a hole, the **last** element moves
   there, and then the array shrinks by one.

Swap-remove has one price, and you must remember it always: **the order of
elements in the dense array is not preserved**. The last element can "teleport"
into the middle. So no system may rely on the iteration order.

---

## 1.7. Why destruction is deferred

This is a consequence of swap-remove, and the single most important rule of the
whole library.

Imagine destruction happened instantly. Within a single frame:

1. System A read entity E and is holding its dense slot — say, 5.
2. System B decides to destroy E. Swap-remove moves **another** entity into
   slot 5.
3. System A reads slot 5 and gets the data of **someone else's entity**.

The program does not crash. There are no errors in the console. The data is just
silently wrong — and you can hunt for that for weeks.

So in Aegis (and in most serious ECS engines) destruction is **deferred**:

```gdscript
world.queue_destroy(entity)    # only marks
# ...and at exactly one point in the frame, in the last system:
world.flush_destroy_queue()    # actually destroys
```

Until the frame ends, no dense slot obtained at its start can go stale. This is
not complexity for complexity's sake — it is what makes the whole construction
safe.

---

## 1.8. System order is behaviour

Another thing that is unusual for people coming from OOP.

In ECS there is no "who calls whom". There is a **list of systems** that runs
top to bottom every frame. And that list is not code formatting, it is a
**behaviour specification**.

```gdscript
scheduler.add_system(MovementSystem.new())      # 1. everyone moved
scheduler.add_system(SpatialIndexSystem.new())  # 2. rebuilt the neighbour index
scheduler.add_system(CollisionSystem.new())     # 3. look for collisions via the index
scheduler.add_system(EcsReaperSystem.new(world))# 4. destroy the marked ones
```

Swap 1 and 2 and the neighbour index is built from the old positions, and
collisions are looked for in the wrong place. The code compiles, the game
starts, there are no errors. The behaviour changes.

So you should treat the system registration list with the same care as an
algorithm. It *is* the algorithm.

---

## 1.9. When ECS is needed and when it is harmful

This is the honest chapter. ECS is not "the better way to write games". It is a
tool with a very specific area of application.

### Suitable

- **Many objects of the same kind**, updated every frame: hundreds to tens of
  thousands. Projectiles, units, crowds, bullet hell, gameplay particles,
  population simulations.
- **You need predictable performance** with no hitches from the garbage
  collector.
- **The target platform is mobile**, or native code is forbidden.
- **Object composition is changeable**: the same thing that became the diamond
  problem in a hierarchy.

### Not suitable

- **You have dozens of objects, not thousands.** Plain Godot nodes are simpler,
  and nobody cares about the speed difference at those numbers. ECS here only
  makes the code more complex — and this is the most common beginner mistake
  with the approach.
- **Every object needs its own node anyway** (its own animation, physics, a
  complex hierarchy). The ECS win is eaten by synchronizing with the scene tree.
- **Complex unique logic per object.** ECS shines where one simple action
  repeats thousands of times, not where a thousand objects do a thousand
  different things.

### A hybrid approach is fine

Most often the right answer is **both**. 10,000 enemies live in ECS and are
drawn through `MultiMeshInstance3D` in one draw call. The player, with their
animations, physics and bone hierarchy, is a plain node. This is not a
compromise or an inconsistency: it is using each tool where it is strong.

---

## 1.10. What Aegis deliberately does not do

So there are no false expectations. Aegis is deliberately a **small** library,
not a stripped-down version of a "real" ECS.

| Missing | Why |
|---|---|
| Automatic archetypes | The game designs the store layout. This keeps cost predictable. |
| Automatic multithreading | The scheduler is sequential. Access metadata is the groundwork for the future. |
| Reactivity "out of the box" | There is an explicit change log (chapter 7), enabled on demand. |
| World serialization | Saving is game-specific, and all the state is already in open arrays. |
| Implicit capacity growth | Growth is an explicit barrier, so an allocation never happens unexpectedly. |
| Bounds checks in the hot primitives | A deliberate trade of safety for speed, in clearly named places. |

---

## Chapter summary

1. ECS exists for the sake of **data layout in memory**, not code beauty.
2. **Entity is a number**, component is data, system is logic.
3. **Sparse set** gives dense iteration and O(1) lookup at the same time; the
   price is an unpredictable element order.
4. **Destruction is deferred** to exactly one point in the frame — otherwise
   swap-remove gives you a silent use-after-free.
5. **System order is behaviour.**
6. ECS is needed for thousands of same-kind objects. With dozens it is harmful.

---

[← Contents](README.md) | Next chapter: [Quick start →](02-quick-start.md)
