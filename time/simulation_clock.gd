class_name SimulationClock
extends RefCounted

## A fixed-step accumulator with a time scale — determinism that survives a
## speed-up.
##
## The library's pause convention (a zero-length step) says nothing about the
## SIZE of the step, and passing the frame's raw delta straight into the
## simulation is fine only while that delta is small. The moment the player can
## speed time up, this stops working: at 50x a 16 ms frame turns into an 800 ms
## step, and anything that advances by a threshold — a cell that divides at
## age 10, a projectile checking whether it flew past its target, a cooldown —
## jumps over several thresholds in a single update. The simulation does not just
## run faster, it produces a DIFFERENT result, and a different one again on a
## slower machine.
##
## A fixed step removes the frame rate from the equation. The clock accumulates
## real time, multiplies it by [member time_scale] and reports how many identical
## [member fixed_step] segments fit into the accumulated time. Every segment is
## identical regardless of the machine and the speed setting, so the result is
## reproducible.
##
## [codeblock]
## var clock := SimulationClock.new()
## clock.fixed_step = 1.0 / 60.0
## clock.time_scale = 4.0
##
## func _process(delta: float) -> void:
##     var steps: int = clock.advance(delta)
##     for i in steps:
##         scheduler.execute_phase(PHASE_SIMULATION, clock.fixed_step)
##     # Presentation runs once per rendered frame, whatever the time scale --
##     # and it runs even at steps == 0, which is what keeps a paused game drawn.
##     scheduler.execute_phase(PHASE_PRESENTATION, delta)
## [/codeblock]
##
## [b]Notice the two different deltas.[/b] The simulation phases get
## [member fixed_step], presentation gets the frame's real delta. Running the
## whole pipeline through the sub-step loop would mean doing the rendering work N
## times per frame for no benefit.
##
## If you do not use phases, the equivalent for a single phase is:
## [codeblock]
## var steps: int = clock.advance(delta)
## if steps == 0:
##     scheduler.execute_all(0.0)          # pause: only systems without requires_time
## else:
##     for i in steps:
##         scheduler.execute_all(clock.fixed_step)
## [/codeblock]

## The length of one simulation segment, in seconds. 1/60 is a good default; a
## slower simulation is fine with 1/30, and that halves the work.
var fixed_step: float = 1.0 / 60.0:
	set(value):
		fixed_step = maxf(value, 0.000001)

## The real-time multiplier. 0 freezes the simulation, 1 is real time, 50 is fast
## forward. Negative values are treated as zero.
var time_scale: float = 1.0

## The upper bound on the number of segments a single [method advance] can
## return.
##
## This is the safety valve against the "death spiral". If one frame was slow,
## more time than usual accumulated; running all the accumulated time makes this
## frame even slower, which accumulates even more. Beyond this number the surplus
## is DROPPED — the simulation briefly runs in slow motion instead of locking up.
## Raise the value to tolerate larger stalls, lower it to bound the worst frame.
var max_substeps: int = 8

## Freezes the clock without losing either the accumulator or the time scale.
var paused: bool = false

## How many seconds of simulation have elapsed since the last [method reset].
## Grows by exactly `fixed_step` per segment, so the value is exact, not
## drifting.
var elapsed_simulated: float = 0.0

## How many segments have been produced in total since the last [method reset].
var total_substeps: int = 0

## How many segments the [member max_substeps] valve has discarded since the last
## [method reset]. A steady rise means the simulation cannot keep up with the
## requested [member time_scale].
var dropped_substeps: int = 0

var _accumulator: float = 0.0
var _last_substeps: int = 0


## Takes one real frame and returns how many fixed segments to run now. Call it
## exactly once per frame.
func advance(real_delta: float) -> int:
	_last_substeps = 0
	if paused or real_delta <= 0.0 or time_scale <= 0.0:
		return 0
	_accumulator += real_delta * time_scale
	var steps: int = int(_accumulator / fixed_step)
	if steps <= 0:
		return 0
	if steps > max_substeps:
		var discarded: int = steps - max_substeps
		dropped_substeps += discarded
		_accumulator -= float(discarded) * fixed_step
		steps = max_substeps
	_accumulator -= float(steps) * fixed_step
	_last_substeps = steps
	total_substeps += steps
	elapsed_simulated += float(steps) * fixed_step
	return steps


## How many segments the last [method advance] returned.
func get_last_substeps() -> int:
	return _last_substeps


## The fraction of a segment currently sitting unspent in the accumulator, in
## [0, 1).
##
## This is the interpolation factor for smooth rendering: draw a moving object as
## `previous_position.lerp(current_position, clock.get_alpha())` and it stops
## looking steppy when the simulation rate is below the frame rate.
func get_alpha() -> float:
	return clampf(_accumulator / fixed_step, 0.0, 1.0)


## True while the valve is discarding time, that is, while the requested time
## scale exceeds what the machine can actually simulate.
func is_saturated() -> bool:
	return _last_substeps >= max_substeps


## How many seconds of simulation are produced per second of real time at the
## current settings. Useful for a HUD that shows the actual (not the requested)
## speed.
func get_effective_time_scale(real_delta: float) -> float:
	if real_delta <= 0.0:
		return 0.0
	return float(_last_substeps) * fixed_step / real_delta


## Clears the accumulator and every counter. Call it on a level restart so a long
## stall before the reset does not spill segments into the new run.
func reset() -> void:
	_accumulator = 0.0
	_last_substeps = 0
	elapsed_simulated = 0.0
	total_substeps = 0
	dropped_substeps = 0
