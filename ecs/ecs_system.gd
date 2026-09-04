class_name EcsSystem
extends RefCounted

## An abstract unit of simulation logic.
##
## In ECS a system is pure logic with no game data of its own. A system does NOT
## keep world-owned state in its fields (no "list of all enemies"); instead it
## re-reads and re-writes the component stores every frame. That is what
## separates a system from an ordinary game object: a system is essentially a
## "what to do with this data" function wrapped in a class, not an entity with a
## life of its own.
##
## Systems are executed by [EcsScheduler] in a FIXED order, defined explicitly at
## registration. That order is itself part of the game's behaviour (the classic
## example: the neighbour-search index must be rebuilt AFTER objects have moved,
## but BEFORE anything searches it).
##
## [b]About the `context` parameter[/b] in [method setup]: it is deliberately
## untyped. The library knows nothing about your game, so it passes the context
## object through as-is — usually your own class with references to all the
## component stores, configuration and shared state. Assign it to a typed field
## in your system:
## [codeblock]
## var _context: MyContext
##
## func setup(_world: EcsWorld, context) -> void:
##     _context = context
## [/codeblock]

## The system's name. Shown in profiling ([EcsScheduler]), so set it in the
## subclass's `_init()` — otherwise every system in the report has the same name.
var system_name: String = "UnnamedSystem"

## Optional grouping. The scheduler never reorders systems: a phase is used for
## selective execution, diagnostics and future scheduling tools.
var system_phase: int:
	get:
		return _system_phase
	set(value):
		if _phase_locked:
			push_error("EcsSystem(%s): the phase can only be changed through EcsScheduler" % system_name)
			return
		_system_phase = value

## A runtime switch. A disabled system keeps its stable index in the scheduler
## and reports zero time for the frames it was skipped.
var enabled: bool = true

## Declares that the system does nothing when time is not advancing.
##
## Pause in this library is a zero-length step, not a skipped frame, so that
## rendering and other time-independent systems keep working. Historically every
## time-dependent system had to begin with `if delta <= 0.0: return`, and a
## forgotten line was a silent bug.
##
## Instead, set this to `true` in `_init()`. Then the scheduler skips the call
## entirely while `delta <= 0.0` — which is both safer and slightly faster than
## an early return. Leave it `false` for systems that must run while paused too:
## rendering, the camera, input, HUD upload.
var requires_time: bool = false

## An optional access description. It adds no checks to the hot path and does not
## change the execution order; tools use it to validate Views and to work out
## which systems could safely be parallelized in a future scheduler.
var read_component_types: PackedInt32Array = PackedInt32Array()
var write_component_types: PackedInt32Array = PackedInt32Array()
var structural_write_component_types: PackedInt32Array = PackedInt32Array()
var writes_world_structure: bool = false
var access_metadata_complete: bool = false

var _system_phase: int = 0
var _phase_locked: bool = false
var _scheduler_owner_id: int = 0


## Called once, after EVERY component store has been registered in the world and
## the whole system pipeline is assembled — that is, the system can safely store
## a reference to [param _context] (or to specific stores from it), knowing they
## already exist and are initialized.
##
## Caching store references here is good practice, not a violation of the
## "systems keep no data" principle: what is cached is a REFERENCE to an existing
## store, not a copy of the data.
func setup(_world: EcsWorld, _context) -> void:
	pass


## Called in reverse registration order from EcsScheduler.teardown_all().
func teardown() -> void:
	pass


## Called once per frame, in the order defined by [EcsScheduler].
## [param _delta] is the simulation step in seconds.
##
## [b]The pause convention[/b]: pause is implemented by passing a zero step, not
## by skipping the call, so that rendering and other time-independent systems
## keep working. Set [member requires_time] to `true` and the scheduler skips
## this system on its own while the step is zero.
func execute(_delta: float) -> void:
	pass


func declare_read(component_type_id: int) -> EcsSystem:
	_append_unique(read_component_types, component_type_id)
	return self


func declare_write(component_type_id: int) -> EcsSystem:
	_append_unique(write_component_types, component_type_id)
	return self


func declare_structural_write(component_type_id: int) -> EcsSystem:
	_append_unique(structural_write_component_types, component_type_id)
	return self


func has_declared_access(component_type_id: int) -> bool:
	return read_component_types.has(component_type_id) \
		or write_component_types.has(component_type_id) \
		or structural_write_component_types.has(component_type_id)


func complete_access_metadata() -> EcsSystem:
	access_metadata_complete = true
	return self


## A cold hook for the scheduler only. A system instance belongs to one
## scheduler; a shared instance would let one scheduler change the phase state
## behind another's back.
func _assign_phase(value: int, scheduler_owner_id: int) -> bool:
	if _scheduler_owner_id != 0 and _scheduler_owner_id != scheduler_owner_id:
		push_error("EcsSystem(%s): one instance cannot be registered in two schedulers" % system_name)
		return false
	_scheduler_owner_id = scheduler_owner_id
	_system_phase = value
	_phase_locked = true
	return true


func _append_unique(values: PackedInt32Array, value: int) -> void:
	if not values.has(value):
		values.append(value)
