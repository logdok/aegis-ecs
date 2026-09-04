[← Spatial search](08-spatial-search.md) | [Contents](README.md) | [Common mistakes →](10-common-mistakes.md)

---

# 9. Performance

---

## 9.1. The GDScript cost model

This is the most important chapter for optimization, and it contradicts the
intuition built up in C++ or Rust.

In a native language the bottleneck is usually **memory traffic**: cache misses,
bus bandwidth. In GDScript it is different: the code is executed by a **virtual
machine**, and cost is determined first and foremost by the **number of bytecode
operations**.

Measured on Godot 4.7.1:

| Operation | Cost |
|---|---|
| Reading a `Packed*Array` element through a local variable | **≈ 20 ns** |
| Calling an empty virtual method | **≈ 90 ns** |
| Reading an element through a container (`array_list[i][j]`) | ≈ 43 ns |

**A method call costs as much as 4–5 array reads.** Almost everything in this
library's architecture follows from that fact.

### Three practical consequences

**1. Lift arrays into local variables before the loop.**

```gdscript
# Bad: reading an object field on every iteration
for i in store.count:
    store.x[i] += store.vx[i] * delta

# Good: one field read, then local variables
var x: PackedFloat32Array = store.x
var vx: PackedFloat32Array = store.vx
for i in store.count:
    x[i] += vx[i] * delta
```

In Godot 4, `Packed*Array` is passed **by reference**, so writes through the
alias land in the store immediately — there is **nothing to assign back**.

**2. Do not wrap element access in methods.**

That is exactly why `sparse_index`, `dense_entities` and `count` are public. A
getter per element would turn 20 ns into 110 ns.

**3. Fewer passes is better — but only if it really reduces the number of
operations.** Merging two loops into one makes sense; wrapping a loop in a
"pretty" abstraction with a callback does not.

---

## 9.2. Library measurements

MacBook, Godot 4.7.1, `--headless`, best of 5 runs, 10,000 entities. Reproduce on
your machine:

```bash
godot --headless --script res://addons/aegis_ecs/tests/benchmark_ecs.gd
```

The numbers are for understanding **ratios**, not as a guarantee: on a mobile
device expect several times slower.

### Destruction

| Scenario | Time |
|---|---|
| 10k entities × 12 stores, 4 components per entity | **7.50 ms** |
| 10k entities × 12 stores, 12 components per entity | **14.66 ms** |
| 10k entities, 2 large stores + 10 small ones (32 each) | **5.64 ms** |

### Creation

| Scenario | Time |
|---|---|
| `create_entity()` + `attach()`, one at a time | 4.18 ms |
| `create_entities()` + `attach_many()`, batched | **1.76 ms** |

### Iteration and queries

| Scenario | Time |
|---|---|
| Joined dense loop, 10k elements | **0.57 ms** (≈57 ns/element) |
| `EcsQuery.refresh()`, rebuild, 10k candidates | ≈0.90 ms |
| `EcsQuery.refresh()`, cache hit | **≈0.001 ms** |

### Spatial grid

| Scenario | Time |
|---|---|
| `rebuild` 10k, `cell=6`, 3D (10,125 cells) | 2.95 ms |
| `rebuild` 10k, `cell=6`, flat (2,025 cells) | **2.21 ms** |
| `query_nearest` × 512, 3D | 3.51 ms |
| `query_nearest` × 512, flat | **2.94 ms** |

### Hand-written store vs declarative

| Scenario | Time |
|---|---|
| Destroy 10k × 4 stores, hand-written `EcsComponentStore` | 7.55 ms |
| Destroy 10k × 4 stores, `EcsPackedStore` | 7.58 ms |

The difference is within the margin of error. **The declarative store does not
cost you speed** — it compensates for its generality with a batched relocation
that fetches the arrays once per operation instead of once per moved element.

---

## 9.3. Why destruction is so expensive

Destruction is the most expensive structural operation, and it is worth
understanding why.

Destroying one entity means detaching it from **every** registered store. With 12
stores and 10,000 entities that is 120,000 "entity × store" pairs. Even if each
pair costs 60 ns, that is already 7 ms.

The library applies three optimizations here:

**1. Iterate by store, not by entity.** Instead of "for each entity, poll every
store", it is "hand each store the whole list of victims at once". Thanks to
this, the sparse arrays live in local variables, and a pair where there is no
component costs **one local array read** instead of an object field read plus a
method call.

**2. Pick the shorter list.** If a store has fewer components than there are
victims (typical for specialized stores — a "turret" on a single entity), it is
cheaper to iterate the **store**, not the list of 10,000 victims. The world
chooses automatically.

**3. Minimum relocations.** When iterating its own array, the store knows in
advance which elements are doomed and **does not move them** into just-freed slots
only to remove them the next step. When destroying the whole population (level
restart, a wiped-out wave) there are **zero** relocations.

### What this means for your code

- **Fewer stores — cheaper destruction.** Twenty small stores cost more than five
  merged ones, even if the profiler shows this not in the system where the
  problem is.
- **Spread mass deaths out.** If you need to remove 10,000 entities and the frame
  budget does not allow it — destroy them in batches of a few hundred per frame.
- **`world.reset()` is cheaper than a mass `queue_destroy`** if you need to
  remove absolutely everything.

---

## 9.4. How to optimize correctly

### Step 1. Measure, do not guess

```gdscript
for i in scheduler.get_system_count():
    print("%-24s %6d µs" % [
        scheduler.get_system_name(i),
        int(scheduler.get_average_timing_usec(i)),
    ])
```

The profiler is built in for exactly this. A real example from a game:

```
  SpatialIndex                          338 µs     ← 75% of the whole frame
  ProjectileImpact                       54 µs
  TurretTargeting                        41 µs
  ...the rest together                   ~30 µs
```

Optimizing `TurretTargeting` here is wasted effort, even if its code looks the
scariest.

### Step 2. The questions in the right order

1. **Can this work be avoided entirely?** The cheapest operation is the one that
   is not there. Rebuild the index every other frame. Do not check what has not
   changed.
2. **Are the parameters set correctly?** One bad `cell_size` costs more than any
   micro-optimization of code (see
   [section 8.4](08-spatial-search.md#84-the-one-that-matters-most-choosing-cell_size)).
3. **Can fewer entities be processed?** Drive the iteration by the smallest
   store. Move rare traits out into tags.
4. **Can method calls be removed from the loop?** Local aliases, inlined checks
   instead of `matches()`.
5. **And only then** — micro-optimizing the math.

### Step 3. Verify across several runs

A simulation is chaotic: one run proves nothing. Measure with a headless script
across several seeds and compare the final counters, not "by eye".

---

## 9.5. Memory

A rough per-entity estimate:

| What | Bytes per entity |
|---|---|
| World (bookkeeping arrays) | ≈ 23 |
| Each store (sparse + dense) | 8 |
| Each store (payload) | the size of your fields |
| `EcsQuery` without a limit | 4 per query |

For 100,000 entities and 10 stores with a 16-byte payload each:
`100k × (23 + 10 × 24) ≈ 26 MB`.

**Set `maximum_results` on queries** that deliberately return few results. A
hundred full queries at a capacity of 1,000,000 would take about 381 MiB.

---

## 9.6. What the library deliberately does not do

- **Does not check bounds in the hot primitives.** `has()`, `index_of()`,
  `entity_at()` do not validate their argument — a deliberate trade of safety for
  speed in clearly named places.
- **Does not grow on its own.** A hidden allocation in a frame is a hitch at a
  random moment.
- **Does not parallelize.** The scheduler is sequential; access metadata is the
  groundwork for the future, not working multithreading.

---

## Chapter summary

1. In GDScript, cost is the **number of bytecode operations**, not memory
   traffic.
2. A method call ≈ 90 ns, an array read ≈ 20 ns. Everything else follows.
3. **Local array aliases before the loop** is the cheapest and most effective
   optimization.
4. Destruction is expensive in proportion to the **number of stores**; fewer
   stores — cheaper.
5. Profile before you optimize. Your intuition is wrong.
6. `EcsPackedStore` costs no speed compared with a hand-written store.

---

[← Spatial search](08-spatial-search.md) | [Contents](README.md) | [Common mistakes →](10-common-mistakes.md)
