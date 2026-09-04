class_name EcsFrameRecorder
extends RefCounted

## Records what each frame cost, broken down by system, into a fixed-size ring
## buffer.
##
## [b]This is the most useful part.[/b] A live view of the current frame flickers
## too fast to read, and shows whichever frame you happened to look at; the
## interesting frame is almost always already gone. Keeping a window of history
## turns "the numbers jump" into "here is the frame that cost three times the
## median, and here is what it spent the extra on".
##
## It contains no nodes and never touches the scene tree, so it works headless —
## in CI, in a QA build or from a console command — with an interface and
## without. After [method configure] it performs no allocation, so there is no
## reason not to leave it enabled in a release build.
##
## [codeblock]
## var recorder := EcsFrameRecorder.new()
## recorder.configure(scheduler, world)          # once
##
## func _process(delta: float) -> void:
##     scheduler.execute_all(delta)
##     recorder.capture()                        # as the last line of the frame
## [/codeblock]
##
## Read the window back through [EcsFrameStats] (aggregates, spike attribution)
## or [EcsReport] (text/JSON). See also [EcsInspector], which wires all of it up
## in one call.

## How many frames are kept by default: 4 seconds at 60 Hz — enough for a spike
## to land in the window, and still cheap (240 frames x 20 systems x 4 bytes ~ 19 KB).
const DEFAULT_FRAME_CAPACITY: int = 240

## What happened to a system during one frame.
enum Status {
	EXECUTED = 0,
	## Skipped because the system declared `requires_time` and the step was zero.
	SKIPPED_PAUSED = 1,
	## Skipped because the system itself is disabled.
	DISABLED = 2,
	## Skipped because its whole phase is disabled.
	PHASE_OFF = 3,
}

var frame_capacity: int = 0
var system_count: int = 0

var _scheduler: EcsScheduler
var _world: EcsWorld
var _names: PackedStringArray = PackedStringArray()
var _phases: PackedInt32Array = PackedInt32Array()
var _requires_time: PackedByteArray = PackedByteArray()

# Ring buffers. The per-system ones are flat: index = slot * system_count + i.
var _timings: PackedFloat32Array = PackedFloat32Array()
var _status: PackedByteArray = PackedByteArray()
var _frame_total: PackedFloat32Array = PackedFloat32Array()
var _frame_wall: PackedFloat32Array = PackedFloat32Array()
var _frame_substeps: PackedInt32Array = PackedInt32Array()
var _frame_live: PackedInt32Array = PackedInt32Array()
var _frame_pending: PackedInt32Array = PackedInt32Array()
var _frame_capacity_at: PackedInt32Array = PackedInt32Array()
var _frame_structural: PackedInt32Array = PackedInt32Array()
var _frame_id: PackedInt32Array = PackedInt32Array()

var _write: int = 0
var _filled: int = 0
var _frames_seen: int = 0
var _last_structural: int = 0
var _configured: bool = false

## How long the last [method capture] took, in microseconds. An observer that
## measures itself: if this value becomes noticeable against the frame, the
## window is too large or capture is being called too often.
var last_capture_usec: float = 0.0


## Binds to the pipeline and pre-allocates every buffer. Call it once, after
## [method EcsScheduler.setup_all].
func configure(scheduler: EcsScheduler, world: EcsWorld, frames: int = DEFAULT_FRAME_CAPACITY) -> bool:
	if scheduler == null or world == null:
		push_error("EcsFrameRecorder: both a scheduler and a world are required")
		return false
	_scheduler = scheduler
	_world = world
	system_count = scheduler.get_system_count()
	frame_capacity = maxi(frames, 2)

	_names.resize(system_count)
	_phases.resize(system_count)
	_requires_time.resize(system_count)
	for i in system_count:
		_names[i] = scheduler.get_system_name(i)
		_phases[i] = scheduler.get_system_phase(i)
		_requires_time[i] = 1 if scheduler.get_system(i).requires_time else 0

	var cells: int = frame_capacity * maxi(system_count, 1)
	_timings.resize(cells)
	_status.resize(cells)
	_frame_total.resize(frame_capacity)
	_frame_wall.resize(frame_capacity)
	_frame_substeps.resize(frame_capacity)
	_frame_live.resize(frame_capacity)
	_frame_pending.resize(frame_capacity)
	_frame_capacity_at.resize(frame_capacity)
	_frame_structural.resize(frame_capacity)
	_frame_id.resize(frame_capacity)

	_write = 0
	_filled = 0
	_frames_seen = 0
	_last_structural = world.structural_version
	_configured = true
	return true


## Records the frame that just finished. Call it as the last action of the
## frame, after every phase has run.
##
## [param substeps] is how many times the simulation phase ran this frame; pass
## [method SimulationClock.get_last_substeps] with a fixed step, otherwise leave
## it 1. The scheduler's measurements accumulate between `begin_frame()` calls,
## so without this number a fixed-step frame looks N times more expensive per
## system than it is.
##
## [param wall_frame_usec] is the duration of the whole rendered frame, if it is
## known. The difference between it and the recorded ECS total is everything
## outside the scheduler: rendering, physics, other scripts. Exactly the split
## needed to work out whose problem it is when a frame dips.
func capture(substeps: int = 1, wall_frame_usec: float = 0.0) -> void:
	if not _configured:
		return
	var started: int = Time.get_ticks_usec()

	var slot: int = _write
	var base: int = slot * system_count
	var timings: PackedFloat32Array = _timings
	var status: PackedByteArray = _status
	var scheduler: EcsScheduler = _scheduler
	var total: float = 0.0

	for i in system_count:
		var value: float = scheduler.get_timing_usec(i)
		timings[base + i] = value
		total += value
		if scheduler.was_system_executed(i):
			status[base + i] = Status.EXECUTED
		elif not scheduler.is_system_enabled(i):
			status[base + i] = Status.DISABLED
		elif not scheduler.is_phase_allowed(i):
			status[base + i] = Status.PHASE_OFF
		else:
			status[base + i] = Status.SKIPPED_PAUSED

	var world: EcsWorld = _world
	var structural: int = world.structural_version
	_frame_total[slot] = total
	_frame_wall[slot] = wall_frame_usec
	_frame_substeps[slot] = maxi(substeps, 1)
	_frame_live[slot] = world.get_live_count()
	_frame_pending[slot] = world.get_pending_destroy_count()
	_frame_capacity_at[slot] = world.capacity
	_frame_structural[slot] = structural - _last_structural
	_frame_id[slot] = _frames_seen
	_last_structural = structural

	_write = (_write + 1) % frame_capacity
	_filled = mini(_filled + 1, frame_capacity)
	_frames_seen += 1
	last_capture_usec = float(Time.get_ticks_usec() - started)


## Forgets the window without reallocating. Use it after a level restart so
## frames from the previous run do not distort the statistics.
func clear() -> void:
	_write = 0
	_filled = 0
	_frames_seen = 0
	if _world != null:
		_last_structural = _world.structural_version


func is_configured() -> bool:
	return _configured


## How many frames are currently held, from 0 to [member frame_capacity].
func get_frame_count() -> int:
	return _filled


## How many frames have been recorded in total, including already overwritten
## ones.
func get_frames_seen() -> int:
	return _frames_seen


## The ring slot with the most recently recorded frame, or -1 if the window is
## empty.
func get_newest_slot() -> int:
	if _filled == 0:
		return -1
	return (_write - 1 + frame_capacity) % frame_capacity


## The ring slot with the [param age]-th frame from the end (0 is the newest), or
## -1 if that frame has already been evicted.
func get_slot_from_newest(age: int) -> int:
	if age < 0 or age >= _filled:
		return -1
	return (_write - 1 - age + frame_capacity) % frame_capacity


## The ring slot with the [param index]-th oldest frame — for walking the window
## in chronological order.
func get_slot_in_order(index: int) -> int:
	if index < 0 or index >= _filled:
		return -1
	var oldest: int = (_write - _filled + frame_capacity) % frame_capacity
	return (oldest + index) % frame_capacity


# --- reading per-frame values -----------------------------------------------

func get_frame_total_usec(slot: int) -> float:
	return _frame_total[slot]


func get_frame_wall_usec(slot: int) -> float:
	return _frame_wall[slot]


func get_frame_substeps(slot: int) -> int:
	return _frame_substeps[slot]


func get_frame_live_count(slot: int) -> int:
	return _frame_live[slot]


func get_frame_pending_destroy(slot: int) -> int:
	return _frame_pending[slot]


func get_frame_world_capacity(slot: int) -> int:
	return _frame_capacity_at[slot]


## How far `world.structural_version` advanced this frame — a cheap measure of
## how much creation, destruction and component attachment there actually was.
func get_frame_structural_delta(slot: int) -> int:
	return _frame_structural[slot]


## A monotonic frame number, stable even after a slot is reused.
func get_frame_id(slot: int) -> int:
	return _frame_id[slot]


# --- reading per-system values ---------------------------------------------

func get_system_name(index: int) -> String:
	return _names[index]


func get_system_phase(index: int) -> int:
	return _phases[index]


func system_requires_time(index: int) -> bool:
	return _requires_time[index] == 1


func get_timing_usec(slot: int, system_index: int) -> float:
	return _timings[slot * system_count + system_index]


func get_status(slot: int, system_index: int) -> int:
	return _status[slot * system_count + system_index]


## The flat timings buffer — for a consumer that wants to walk the window
## without a method call per cell. Indexed as `slot * system_count + system_index`.
## Read-only.
##
## [EcsFrameStats] uses this rather than [method get_timing_usec]: over a few
## thousand cells, the method call outweighs everything else the analysis does.
func get_timings_unsafe() -> PackedFloat32Array:
	return _timings


## The flat status buffer, indexed the same way as [method get_timings_unsafe]. Read-only.
func get_status_unsafe() -> PackedByteArray:
	return _status


## The ring slot with the oldest held frame, or -1 if the window is empty. With
## it a consumer can walk the window arithmetically, without calling
## [method get_slot_in_order] per frame.
func get_oldest_slot() -> int:
	if _filled == 0:
		return -1
	return (_write - _filled + frame_capacity) % frame_capacity


## An estimate of the memory used by the ring buffer, in bytes.
func get_memory_usage() -> int:
	return _timings.size() * 4 + _status.size() + frame_capacity * 30
