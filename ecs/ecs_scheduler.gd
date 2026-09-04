class_name EcsScheduler
extends RefCounted

## An ordered, deterministic pipeline of systems with built-in per-system
## profiling.
##
## The scheduler keeps ALL of "what runs after what" in one place. The system
## list is defined once while building the world and never changes again; the
## scheduler simply walks it in the same order every frame.
##
## [b]System order is behaviour, not code formatting.[/b] Swapping two
## registration lines changes what happens in the game: if system B reads data
## that system A writes in the same frame, A must come first. Treat the
## registration list as a specification.
##
## [b]Profiling[/b] is the main performance-diagnostics tool, right on the
## device: [method get_timing_usec] gives each system's time in microseconds for
## the last frame, and [method get_average_timing_usec] a smoothed value that is
## much easier to read on a live HUD. Microseconds, not milliseconds, are a
## deliberate choice: cheap systems fit into single-digit microseconds, and a
## millisecond report would be all zeros.
##
## The measurement itself costs two [method Time.get_ticks_usec] calls per system
## per frame. That is little, but if you need to squeeze out the last bit —
## disable [member profiling_enabled] and the loop runs with no measurement at
## all.

## The weight of the newest sample in the smoothed time. Lower is steadier.
const AVERAGE_SMOOTHING: float = 0.1

var profiling_enabled: bool = true

var _systems: Array[EcsSystem] = []
var _timings_usec: PackedFloat32Array = PackedFloat32Array()
var _average_usec: PackedFloat32Array = PackedFloat32Array()
var _phase_allowed: PackedByteArray = PackedByteArray()
var _executed: PackedByteArray = PackedByteArray()
var _is_setup: bool = false
var _world: EcsWorld
var _context


## Registers [param system] in the pipeline and returns it — the order of
## add_system() calls defines the execution order.
func add_system(system: EcsSystem, phase: int = 0) -> EcsSystem:
	if _is_setup:
		push_error("EcsScheduler: add_system() after setup_all() is not allowed")
		return system
	if _systems.has(system):
		push_error("EcsScheduler: the same system object is registered twice")
		return system
	if not system._assign_phase(phase, get_instance_id()):
		return system
	_systems.append(system)
	_timings_usec.resize(_systems.size())
	_average_usec.resize(_systems.size())
	_phase_allowed.append(1)
	_executed.append(0)
	return system


## Calls [method EcsSystem.setup] on every registered system. Call it once, when
## the world, all stores and the whole system list are ready.
func setup_all(world: EcsWorld, context) -> bool:
	if _is_setup:
		push_error("EcsScheduler: setup_all() was already called")
		return false
	_world = world
	_context = context
	for system in _systems:
		system.setup(world, context)
	_is_setup = true
	return true


func teardown_all() -> void:
	if not _is_setup:
		return
	for index in range(_systems.size() - 1, -1, -1):
		_systems[index].teardown()
	_is_setup = false
	_world = null
	_context = null


## Runs ALL systems for one frame, strictly in registration order.
##
## [param delta] is passed to systems as-is. To pause the simulation, pass 0.0:
## systems that declared [member EcsSystem.requires_time] are skipped, while the
## rest (rendering, the camera, the HUD) keep working — see
## [method EcsSystem.execute].
func execute_all(delta: float) -> void:
	if not _is_setup:
		push_error("EcsScheduler: execute_all() before setup_all()")
		return
	begin_frame()
	var total: int = _systems.size()
	var time_stopped: bool = delta <= 0.0
	if profiling_enabled:
		for i in total:
			var system: EcsSystem = _systems[i]
			if not system.enabled or _phase_allowed[i] == 0:
				continue
			if time_stopped and system.requires_time:
				continue
			var started: int = Time.get_ticks_usec()
			system.execute(delta)
			_timings_usec[i] += float(Time.get_ticks_usec() - started)
			_executed[i] = 1
	else:
		for i in total:
			var system: EcsSystem = _systems[i]
			if not system.enabled or _phase_allowed[i] == 0:
				continue
			if time_stopped and system.requires_time:
				continue
			system.execute(delta)
			_executed[i] = 1


## Closes the previous frame's measurements and clears per-frame state. Call it
## once before a series of [method execute_phase] calls; [method execute_all]
## does it itself.
##
## Timings ACCUMULATE between two begin_frame() calls, so a fixed-step frame that
## ran the simulation phase four times reports the total cost of those four
## sub-steps — that is, what actually landed in the frame budget. The smoothed
## average is folded here, once per frame, not per sub-step.
func begin_frame() -> void:
	if profiling_enabled:
		for i in _average_usec.size():
			_average_usec[i] += (_timings_usec[i] - _average_usec[i]) * AVERAGE_SMOOTHING
	_timings_usec.fill(0.0)
	_executed.fill(0)


## Runs one phase in registration order. Phases are a filter and metadata; the
## scheduler never sorts systems automatically.
func execute_phase(phase: int, delta: float) -> void:
	if not _is_setup:
		push_error("EcsScheduler: execute_phase() before setup_all()")
		return
	var time_stopped: bool = delta <= 0.0
	for i in _systems.size():
		var system: EcsSystem = _systems[i]
		if system.system_phase != phase or not system.enabled or _phase_allowed[i] == 0:
			continue
		if time_stopped and system.requires_time:
			continue
		if profiling_enabled:
			var started: int = Time.get_ticks_usec()
			system.execute(delta)
			_timings_usec[i] += float(Time.get_ticks_usec() - started)
		else:
			system.execute(delta)
		_executed[i] = 1


func set_system_enabled(index: int, value: bool) -> void:
	_systems[index].enabled = value
	if not value:
		_timings_usec[index] = 0.0
		_executed[index] = 0


func is_system_enabled(index: int) -> bool:
	return _systems[index].enabled


func set_phase_enabled(phase: int, value: bool) -> void:
	for index in _systems.size():
		if _systems[index].system_phase == phase:
			_phase_allowed[index] = 1 if value else 0
			if not value:
				_timings_usec[index] = 0.0
				_executed[index] = 0


func set_system_phase(index: int, phase: int) -> void:
	var phase_allowed: int = 1
	for other_index in _systems.size():
		if other_index != index and _systems[other_index].system_phase == phase:
			phase_allowed = _phase_allowed[other_index]
			break
	if not _systems[index]._assign_phase(phase, get_instance_id()):
		return
	_phase_allowed[index] = phase_allowed
	_timings_usec[index] = 0.0
	_executed[index] = 0


## Whether system [param index] is allowed to run by its PHASE — as opposed to
## its own [member EcsSystem.enabled] switch.
##
## Tooling needs to tell these apart: "this system is off" and "the whole phase
## it belongs to is off" look identical in the measurements but mean something
## completely different when you are hunting for why something stopped happening.
func is_phase_allowed(index: int) -> bool:
	return _phase_allowed[index] == 1


func is_phase_enabled(phase: int) -> bool:
	for index in _systems.size():
		if _systems[index].system_phase == phase and _phase_allowed[index] == 0:
			return false
	return true


func get_system_count() -> int:
	return _systems.size()


func get_system_name(index: int) -> String:
	return _systems[index].system_name


func get_system(index: int) -> EcsSystem:
	return _systems[index]


func get_system_phase(index: int) -> int:
	return _systems[index].system_phase


## The index of the first system with this name, or -1. Cold path; handy for
## toggling a system by name from a debug panel.
func find_system(name: String) -> int:
	for index in _systems.size():
		if _systems[index].system_name == name:
			return index
	return -1


func was_system_executed(index: int) -> bool:
	return _executed[index] == 1


## The run time of system [param index] for the last frame, in microseconds.
## While [member profiling_enabled] is off, the values are not updated.
func get_timing_usec(index: int) -> float:
	return _timings_usec[index]


## The exponentially smoothed time, in microseconds. Much steadier than the
## per-frame value — this is usually the one a debug overlay wants to show.
func get_average_timing_usec(index: int) -> float:
	return _average_usec[index]


func get_total_timing_usec() -> float:
	var total: float = 0.0
	for timing in _timings_usec:
		total += timing
	return total


func reset_profiling() -> void:
	_timings_usec.fill(0.0)
	_average_usec.fill(0.0)
	_executed.fill(0)


## Cold-path validation — for build tools and tests.
func validate_pipeline(world: EcsWorld, report_errors: bool = true) -> bool:
	var valid := true
	var previous_phase: int = -2_147_483_648
	for system in _systems:
		if system.system_name.is_empty() or system.system_name == "UnnamedSystem":
			valid = false
			if report_errors:
				push_error("EcsScheduler: a system has no diagnostic name")
		if system.system_phase < previous_phase:
			valid = false
			if report_errors:
				push_error("EcsScheduler: phases must be non-decreasing in registration order")
		previous_phase = system.system_phase
		for type_id in system.read_component_types:
			valid = _validate_type(world, system, type_id, report_errors) and valid
		for type_id in system.write_component_types:
			valid = _validate_type(world, system, type_id, report_errors) and valid
		for type_id in system.structural_write_component_types:
			valid = _validate_type(world, system, type_id, report_errors) and valid
	return valid


## Conservative dependency analysis for tooling and future parallel batches. The
## current scheduler stays deliberately sequential.
func systems_conflict(first_index: int, second_index: int) -> bool:
	var first: EcsSystem = _systems[first_index]
	var second: EcsSystem = _systems[second_index]
	if not first.access_metadata_complete or not second.access_metadata_complete:
		return true
	# World lifecycle changes can invalidate raw ids and any View, so they
	# conflict with every system regardless of component declarations.
	if first.writes_world_structure or second.writes_world_structure:
		return true
	if _intersects(first.write_component_types, second.read_component_types) \
			or _intersects(first.write_component_types, second.write_component_types) \
			or _intersects(first.write_component_types, second.structural_write_component_types) \
			or _intersects(second.write_component_types, first.read_component_types) \
			or _intersects(second.write_component_types, first.structural_write_component_types):
		return true
	if _structural_conflict(first.structural_write_component_types, second) \
			or _structural_conflict(second.structural_write_component_types, first):
		return true
	return false


func _validate_type(world: EcsWorld, system: EcsSystem, type_id: int, report_errors: bool) -> bool:
	if world.has_store(type_id):
		return true
	if report_errors:
		push_error("EcsScheduler: system %s references an unregistered type %d" % [system.system_name, type_id])
	return false


func _structural_conflict(types: PackedInt32Array, system: EcsSystem) -> bool:
	return _intersects(types, system.read_component_types) \
		or _intersects(types, system.write_component_types) \
		or _intersects(types, system.structural_write_component_types)


func _intersects(first: PackedInt32Array, second: PackedInt32Array) -> bool:
	for value in first:
		if second.has(value):
			return true
	return false
