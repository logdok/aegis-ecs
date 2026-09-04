[← Full example](11-full-example.md) | [Contents](README.md)

---

# 12. API reference

The complete list of the public API. The "why it is this way" explanations are in
the relevant chapters, with links added.

---

## `EcsWorld`

The identifier allocator and store registry. See
[chapter 3](03-world-entities-lifecycle.md).

### Constants

| Constant | Value |
|---|---|
| `INVALID_ENTITY` | `-1` |
| `INVALID_HANDLE` | `0` |

### Assembly

| Method | Description |
|---|---|
| `_init(entity_capacity)` | Set the capacity and allocate all buffers at once |
| `register_store(store, type_id) -> bool` | Register a store **before** the first entity |
| `get_store(type_id) -> EcsComponentStore` | Lookup by type. For assembly and debugging, **not for the hot loop** |
| `has_store(type_id) -> bool` | |
| `get_store_count() -> int` | |
| `get_store_at(index) -> EcsComponentStore` | |
| `is_schema_locked() -> bool` | Whether entities have been created yet |

### Creation

| Method | Description |
|---|---|
| `create_entity() -> int` | A new id, or **-1** if the world is full |
| `create_entities(count, out_entities) -> int` | Batched; returns how many were actually created |
| `create_entity_handle() -> int` | Create and get a handle at once |

### Handles

| Method | Description |
|---|---|
| `make_handle(entity) -> int` | A safe reference that survives across frames |
| `entity_from_handle(handle) -> int` | Resolve, or `INVALID_ENTITY` |
| `is_handle_alive(handle) -> bool` | |
| `get_generation(entity) -> int` | |
| `get_world_tag() -> int` | |

### Destruction

| Method | Description |
|---|---|
| `queue_destroy(entity) -> bool` | Mark. Idempotent |
| `queue_destroy_many(entities, count) -> int` | Batched; returns how many were added to the queue |
| `queue_destroy_handle(handle) -> bool` | |
| `flush_destroy_queue() -> int` | **Structural sync point.** At exactly one point in the frame |
| `is_pending_destroy(entity) -> bool` | |
| `is_handle_pending_destroy(handle) -> bool` | |
| `is_alive(entity) -> bool` | With a bounds check |

### Capacity and reset

| Method | Description |
|---|---|
| `reserve_capacity(n) -> bool` | An explicit allocating barrier. `false` if some store does not support growth |
| `reset()` | Clear the world **with no allocations**; invalidates all handles |
| `capacity` | Current capacity (read-only) |

### Diagnostics

| Method | Description |
|---|---|
| `get_live_count()` / `get_free_count()` / `get_retired_count()` | |
| `get_pending_destroy_count()` | |
| `get_load_factor() -> float` | `live / capacity`, in `[0, 1]` |
| `structural_version` | A monotonic counter of structural changes |
| `validate_integrity(report_errors = true) -> bool` | A full check. **Not for a production frame** |
| `clear_change_logs()` | Clear the logs of every store that has them enabled |

---

## `EcsComponentStore`

The abstract sparse-set store. See
[chapter 4](04-components-and-stores.md).

### Public fields

| Field | Description |
|---|---|
| `type_id` | The type identifier it is registered under |
| `debug_name` | Optional name for tooling; falls back to the script's `class_name` |
| `sparse_index` | `entity → slot`, or -1. **Read-only from outside** |
| `dense_entities` | `slot → entity`. **Read-only from outside** |
| `count` | The number of components = the length of the dense array |
| `structural_version` | Changes only when membership/layout changes |

### The change log ([section 7.2](07-time-events-capacity.md#72-the-change-log--reacting-to-birth-and-death))

| Field / method | Description |
|---|---|
| `track_changes: bool` | Enable the log. `false` by default |
| `added_entities`, `added_count` | Valid prefix `[0, added_count)` |
| `removed_entities`, `removed_count` | Valid prefix `[0, removed_count)` |
| `change_log_overflowed` | `clear()`/`reset()` did not log removals element by element |
| `clear_change_log()` | Clear both logs |

### Operations

| Method | Description |
|---|---|
| `attach(entity) -> int` | Attach; idempotent; -1 on overflow |
| `attach_many(entities, count) -> int` | Batched; new slots are contiguous from `count` **before** the call |
| `detach(entity)` | Safe, even if there is no component |
| `detach_many(entities, count) -> int` | Batched by a list of victims |
| `detach_flagged(flags) -> int` | Batched by byte flags; minimum relocations |
| `has(entity) -> bool` | **No bounds check** |
| `index_of(entity) -> int` | Slot or -1. **No bounds check** |
| `entity_at(slot) -> int` | **No bounds check** |
| `clear()` | Empty with no allocations |
| `get_debug_name() -> String` | Name for tooling; `class_name`, then `"type N"` |
| `get_capacity() -> int` | |
| `is_initialized() -> bool` | |
| `supports_capacity_growth() -> bool` | Whether `_grow_dense()` is defined |
| `validate_integrity(alive, report) -> bool` | Check the sparse↔dense bijection |

### Virtual methods

**Mandatory** (declared in the base):

| Method | Description |
|---|---|
| `_reserve_dense(capacity)` | Allocate your payload arrays |
| `_relocate_dense(from, to)` | Relocate data on swap-remove |

**Optional** — detected automatically via `has_method()`. Define it — it works;
do not — it costs nothing.

| Method | Description |
|---|---|
| `_grow_dense(prev, next)` | Enables `world.reserve_capacity()` |
| `_relocate_dense_batch(from, to, n)` | Batched relocation |
| `_release_dense(slot)` | Free ownership **before** it is overwritten |
| `_clear_relocated_dense(slot)` | Clear the duplicate in the source slot |
| `_clear_dense(active_count)` | Bulk cleanup on `clear()`/`reset()` |

---

## `EcsPackedStore`

The declarative store. Implements `_reserve_dense`, `_grow_dense`,
`_relocate_dense` and `_relocate_dense_batch` generically.

| Method | Description |
|---|---|
| `track(a, b, ...)` | Register up to 8 fields by name. Call it in `_init()` |
| `track_field(name)` | Register one field |
| `refresh_tracked_arrays()` | If a field was assigned a whole new array |
| `get_tracked_field_count() -> int` | |
| `get_tracked_field_name(i) -> StringName` | |
| `clear_slot(slot)` | Write the type-appropriate zero into all fields of this slot |
| `get_field_value(field_index, slot) -> Variant` | Generic payload read for tooling. Cold path |
| `describe_entity(entity) -> Dictionary` | All tracked fields of one entity as `{name: value}` |

**Supported field types:** any `Packed*Array` and a plain `Array`.

---

## `EcsTagStore`

A data-less marker component. The whole API is inherited; the specialized
`detach_many()` and `detach_flagged()` perform no relocations at all.

---

## `EcsView`

A store intersection with no materialization. See
[section 6.2](06-finding-entities.md#62-level-2-ecsview-no-allocations).

| Method | Description |
|---|---|
| `configure(world, required, excluded = [], owner = null) -> bool` | A cold operation, once |
| `refresh_driver()` | Pick the smallest of the required stores |
| `get_candidate_store() -> EcsComponentStore` | The driver store |
| `get_candidate_count() -> int` | |
| `get_driver_required_index() -> int` | The driver's index among the required |
| `matches(entity) -> bool` | Membership check |
| `get_required_count()` / `get_required_store(i)` / `get_required_sparse(i)` | |
| `get_excluded_count()` / `get_excluded_store(i)` / `get_excluded_sparse(i)` | |
| `is_configured() -> bool` | |
| `validate_owner_access(report = true) -> bool` | Check the owner system's metadata |

---

## `EcsQuery`

A materialized cache on top of `EcsView`. See
[section 6.3](06-finding-entities.md#63-level-3-ecsquery-cached-result).

| Method | Description |
|---|---|
| `configure(world, required, excluded = [], owner = null, maximum_results = -1) -> bool` | |
| `refresh() -> bool` | `true` if the cache was rebuilt |
| `is_current() -> bool` | Whether the cache is up to date |
| `count` | The result size |
| `entity_at(i) -> int` | |
| `get_entities_unsafe() -> PackedInt32Array` | Fast buffer, **read-only** |
| `get_result_capacity() -> int` | |
| `is_truncated() -> bool` | More matched than the limit holds |
| `get_rebuild_count() -> int` | How many times it was rebuilt |
| `get_view() -> EcsView` | |
| `validate_owner_access(report = true) -> bool` | |

---

## `EcsSystem`

A unit of logic. See [chapter 5](05-systems-and-scheduler.md).

| Field | Description |
|---|---|
| `system_name` | Set in `_init()`; shows up in profiling |
| `system_phase` | Frozen after `add_system()`; change it via the scheduler |
| `enabled` | Runtime switch |
| `requires_time` | `true` → the scheduler skips the system when `delta <= 0` |
| `read_component_types` / `write_component_types` / `structural_write_component_types` | Metadata |
| `writes_world_structure` | `create`/`destroy`/`reset` |
| `access_metadata_complete` | |

| Method | Description |
|---|---|
| `setup(world, context)` | Once, when everything is ready. Cache references here |
| `execute(delta)` | Once per frame |
| `teardown()` | In reverse registration order |
| `declare_read(id)` / `declare_write(id)` / `declare_structural_write(id)` | Chainable |
| `has_declared_access(id) -> bool` | |
| `complete_access_metadata()` | Confirm the description is complete |

---

## `EcsScheduler`

| Method | Description |
|---|---|
| `add_system(system, phase = 0) -> EcsSystem` | Registration order = execution order |
| `setup_all(world, context) -> bool` | |
| `teardown_all()` | In reverse order |
| `execute_all(delta)` | The whole pipeline |
| `begin_frame()` | Close the previous frame; mandatory before a series of `execute_phase()` |
| `execute_phase(phase, delta)` | One phase; timings **accumulate** until `begin_frame()` |
| `set_system_enabled(i, value)` / `is_system_enabled(i)` | |
| `set_phase_enabled(phase, value)` / `is_phase_enabled(phase)` | |
| `is_phase_allowed(i) -> bool` | Whether the system's phase allows it to run |
| `set_system_phase(i, phase)` | A safe phase change |
| `get_system_count()` / `get_system_name(i)` / `get_system(i)` / `get_system_phase(i)` | |
| `find_system(name) -> int` | Index or -1 |
| `was_system_executed(i) -> bool` | |
| `get_timing_usec(i) -> float` | Last frame |
| `get_average_timing_usec(i) -> float` | Smoothed; for the HUD |
| `get_total_timing_usec() -> float` | |
| `reset_profiling()` | |
| `profiling_enabled` | Turn measurement off |
| `validate_pipeline(world, report = true) -> bool` | |
| `systems_conflict(a, b) -> bool` | Conservative dependency analysis |

---

## `EcsReaperSystem`

The single point of destruction. Register it **last**.

| Member | Description |
|---|---|
| `_init(world = null, name = "Reaper")` | |
| `last_reaped` | Destroyed this frame |
| `total_reaped` | Destroyed in total |

Has `requires_time = false` deliberately: the queue must be drained while paused
too.

---

## `EcsCapacityPolicySystem`

Automatic world growth. Register it **right after the reaper**.

| Member | Description |
|---|---|
| `_init(world = null, name = "CapacityPolicy")` | |
| `grow_threshold` | Fill fraction to grow at. `0.85` by default |
| `growth_factor` | New capacity multiplier. `1.5` by default |
| `maximum_capacity` | Ceiling; `0` = no limit |
| `check_interval_frames` | `30` by default |
| `on_capacity_grown: Callable` | `call(previous, next)` after growth |
| `grow_now() -> bool` | Force it, ignoring the interval |
| `growth_count`, `last_growth_capacity` | Diagnostics |

---

## `SimulationClock`

Fixed step and time scale. See
[section 7.1](07-time-events-capacity.md#71-simulationclock--fixed-step-and-time-scale).

| Member | Description |
|---|---|
| `advance(real_delta) -> int` | How many sub-steps to run. **Exactly once per frame** |
| `fixed_step` | The length of a simulation segment |
| `time_scale` | `0` = stop, `1` = real time |
| `max_substeps` | The safety valve against the "death spiral". `8` by default |
| `paused` | Freeze without losing the accumulator |
| `get_last_substeps() -> int` | |
| `get_alpha() -> float` | The fraction of the unspent segment, for interpolation |
| `is_saturated() -> bool` | Whether it is hitting `max_substeps` |
| `get_effective_time_scale(real_delta) -> float` | The actual rate |
| `elapsed_simulated` | The exact sum, with no drift |
| `total_substeps`, `dropped_substeps` | |
| `reset()` | |

---

## `UniformSpatialGrid`

A broadphase built on counting sort. See [chapter 8](08-spatial-search.md).

| Constant | Value |
|---|---|
| `MAX_QUERY_RESULTS` | `2048` |

| Method | Description |
|---|---|
| `configure(arena_radius, vertical_extent, cell_size, entry_capacity)` | `vertical_extent = 0` → flat 2D mode |
| `suggest_cell_size(arena_radius, vertical_extent, expected_entries, query_radius) -> float` | **Static.** A reasoned starting point |
| `rebuild(entity_ids, points, entry_count)` | A full rebuild |
| `query_nearest(center, radius) -> int` | The nearest id, or -1. No allocations |
| `query_sphere(center, radius, limit) -> int` | The count; the ids are in `query_buffer` |
| `get_cell_index(point) -> int` | |
| `get_cell_start(cell)` / `get_cell_end(cell)` | The cell's bounds in the sorted arrays |
| `get_entry_count()` / `get_cell_count()` / `get_cell_size()` | |
| `get_dimensions() -> Vector3i` | Cells per axis; `y == 1` in flat mode |
| `is_flat() -> bool` | |

| Field | Description |
|---|---|
| `query_buffer` | The result of the last `query_sphere`. **Overwritten by the next query** |
| `query_point_buffer` | Positions; filled only when `store_query_points = true` |
| `store_query_points` | `false` by default |
| `sorted_entities`, `sorted_points` | Sorted by cell. **Read-only** |

---

## `AngleMath`

| Method | Description |
|---|---|
| `approach(current, desired, max_step) -> float` | **Static.** Turn along the shortest path |
| `shortest_delta(from, to) -> float` | **Static.** The absolute angular distance |

---

## The debug part

Fully described in [chapter 13](13-inspector.md). The `debug/` folder contains no
nodes and is safe in a release build; `inspector/` contains the panel and is
stripped from the export.

### `EcsInspector`

The single point of attachment.

| Member | Description |
|---|---|
| `attach(scheduler, world, options) -> EcsInspector` | **Static.** Never returns `null` |
| `capture()` | **As the last line of the frame.** Also measures wall-clock time |
| `refresh_now()` | Recompute aggregates and diagnostics immediately |
| `add_counter_section(title, provider: Callable)` | Application counters |
| `register_query(name, query)` / `register_grid(name, grid)` / `set_clock(clock)` | Objects for diagnostics |
| `get_findings() -> Array` | Findings, worst first |
| `has_panel()` / `get_panel()` / `set_panel_visible(v)` | The interface, if there is one |
| `print_report()` / `print_worst_frame()` / `save_report(dir)` | Reports |
| `detach()` | Remove the panel and stop collecting |
| `mode` | `OFF` / `TELEMETRY` / `INSPECTOR` / `DEV` |
| `stats_refresh_hz`, `diagnostics_refresh_hz` | Recompute rates |
| `recorder`, `stats`, `diagnostics` | Direct access to the parts |

`options` keys: `mode`, `parent`, `frames`, `clock`, `grids`, `queries`,
`budget_usec`.

### `EcsFrameRecorder`

A ring buffer of frames. Allocates nothing after `configure()`.

| Member | Description |
|---|---|
| `configure(scheduler, world, frames = 240) -> bool` | |
| `capture(substeps = 1, wall_frame_usec = 0.0)` | |
| `clear()` | Forget the window without reallocating |
| `get_frame_count()` / `get_frames_seen()` | |
| `get_newest_slot()` / `get_oldest_slot()` / `get_slot_in_order(i)` / `get_slot_from_newest(age)` | |
| `get_frame_total_usec(slot)` / `get_frame_wall_usec(slot)` / `get_frame_substeps(slot)` | |
| `get_frame_live_count(slot)` / `get_frame_pending_destroy(slot)` / `get_frame_structural_delta(slot)` | |
| `get_timing_usec(slot, system)` / `get_status(slot, system)` | |
| `get_timings_unsafe()` / `get_status_unsafe()` | Flat buffers, read-only |
| `last_capture_usec` / `get_memory_usage()` | The cost of observing |
| `Status` | `EXECUTED` / `SKIPPED_PAUSED` / `DISABLED` / `PHASE_OFF` |

### `EcsFrameStats`

| Member | Description |
|---|---|
| `analyse(recorder) -> bool` | Cold path: sorts the window |
| `get_frame_median_usec()` / `get_frame_p95_usec()` / `get_frame_max_usec()` / `get_frame_average_usec()` | |
| `get_worst_frame_slot()` | The slot of the worst frame — for a full breakdown |
| `get_spike_frame_count()` / `get_spike_ratio()` | Are there spikes |
| `get_system_median_usec(i)` / `get_system_p95_usec(i)` / `get_system_max_usec(i)` | |
| `get_system_share_percent(i)` | Fraction of ECS time |
| `get_system_volatility(i)` | `max / median` — who causes spikes |
| `get_system_excess_share(i)` | Fraction of the excess in slow frames |
| `get_spike_contributor(rank)` | Ranking of the culprits |
| `get_live_min()` / `get_live_max()` / `get_capacity_change_count()` / `get_peak_pending_destroy()` | |
| `spike_factor`, `high_percentile` | Settings |

### `EcsDiagnostics`

| Member | Description |
|---|---|
| `inspect(recorder, stats, world, extras = {}) -> Array` | Findings, worst first |
| `reset()` | Forget the query rebuild counters |
| `frame_budget_usec`, `volatility_warning`, `load_factor_warning`, `store_fill_warning`, `spike_ratio_warning`, `dominant_share_percent`, `excess_share_warning` | Thresholds |
| `EcsDiagnostics.Finding` | `severity`, `source`, `title`, `detail`, `hint`, `format()` |

### `EcsReport`

All methods are static.

| Method | Description |
|---|---|
| `to_text(recorder, stats, world, findings) -> String` | A report for a ticket |
| `frame_to_text(recorder, slot, stats) -> String` | A breakdown of one frame |
| `to_dictionary(...) -> Dictionary` | For JSON |
| `to_csv(recorder) -> String` | One row per frame, one column per system |
| `save_text(path, ...)` / `save_json(path, ...)` / `save_csv(path, ...)` | |

---

[← Full example](11-full-example.md) | [Contents](README.md) | [Inspector →](13-inspector.md)
