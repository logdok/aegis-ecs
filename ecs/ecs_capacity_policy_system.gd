class_name EcsCapacityPolicySystem
extends EcsSystem

## Grows the world BEFORE it runs out of entity identifiers.
##
## [method EcsWorld.create_entity] returns -1 when the world is full, and
## [method EcsWorld.reserve_capacity] is an explicit allocating barrier that must
## not run in the middle of a system iteration. That combination is fine while
## the population is predictable, but a simulation with explosive growth — a
## dividing cell culture, a wave spawner, a chain reaction — can double its
## population in seconds and start silently losing spawns.
##
## This system checks the fill factor once every [member check_interval_frames]
## frames and grows the world as soon as it crosses the [member grow_threshold]
## — so growth happens while there is still room, not after spawns have already
## been lost.
##
## [codeblock]
## var policy := EcsCapacityPolicySystem.new(world)
## policy.grow_threshold = 0.8
## policy.growth_factor = 1.5
## policy.maximum_capacity = 200_000
## policy.on_capacity_grown = _resize_my_render_buffers
## scheduler.add_system(EcsReaperSystem.new(world))
## scheduler.add_system(policy)                       # right after the reaper
## [/codeblock]
##
## [b]Register it right after the reaper[/b] or at another explicit phase
## boundary. Growth reallocates all the world's and stores' buffers, so no system
## may be holding a dense slot or a cached array alias across that call.
##
## The library can only grow its OWN buffers. Everything the game allocated
## alongside — `MultiMesh`, physics batches, network arrays — is grown by your
## [member on_capacity_grown] callback.

## Grow when this fraction of the world is occupied by live entities.
var grow_threshold: float = 0.85

## The new capacity is the old one multiplied by this number. 1.5 makes
## reallocation rare without doubling the memory on every step.
var growth_factor: float = 1.5

## A hard ceiling. 0 means "no limit beyond what the handle layout allows".
var maximum_capacity: int = 0

## How often the check runs. Checking every frame is pointless: the fill factor
## cannot move noticeably in one frame, and growth is a rare event.
var check_interval_frames: int = 30

## Called as `callable.call(previous_capacity, new_capacity)` after a successful
## growth, so the game can grow buffers the library does not know about.
var on_capacity_grown: Callable = Callable()

## Diagnostics.
var growth_count: int = 0
var last_growth_capacity: int = 0

var _world: EcsWorld
var _frames_since_check: int = 0


func _init(world: EcsWorld = null, system_display_name: String = "CapacityPolicy") -> void:
	system_name = system_display_name
	writes_world_structure = true
	complete_access_metadata()
	_world = world


func setup(world: EcsWorld, context) -> void:
	if _world == null:
		_world = world
	if _world == null and context != null and context.get(&"world") != null:
		_world = context.get(&"world")
	if _world == null:
		push_error("EcsCapacityPolicySystem: no world — pass it to _init() or setup()")


func execute(_delta: float) -> void:
	if _world == null:
		return
	_frames_since_check += 1
	if _frames_since_check < check_interval_frames:
		return
	_frames_since_check = 0
	if _world.get_load_factor() < grow_threshold:
		return
	grow_now()


## Runs the growth check immediately, ignoring the interval. Use it right before
## a spike whose size you already know in advance.
func grow_now() -> bool:
	if _world == null:
		return false
	var previous_capacity: int = _world.capacity
	var target: int = int(ceil(float(previous_capacity) * maxf(growth_factor, 1.01)))
	if target <= previous_capacity:
		target = previous_capacity + 1
	if maximum_capacity > 0:
		target = mini(target, maximum_capacity)
	if target <= previous_capacity:
		return false
	if not _world.reserve_capacity(target):
		return false
	growth_count += 1
	last_growth_capacity = target
	if on_capacity_grown.is_valid():
		on_capacity_grown.call(previous_capacity, target)
	return true
