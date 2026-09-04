class_name EcsReaperSystem
extends EcsSystem

## The only system that actually destroys entities.
##
## Every other system merely calls [method EcsWorld.queue_destroy]; the real
## removal happens here, in [method EcsWorld.flush_destroy_queue]. This class
## exists so that the library's most important rule is something you REGISTER
## rather than something you must remember to write:
##
## [codeblock]
## scheduler.add_system(SpawnSystem.new())
## scheduler.add_system(MovementSystem.new())
## scheduler.add_system(DamageSystem.new())
## scheduler.add_system(EcsReaperSystem.new(world))   # always last
## [/codeblock]
##
## [b]Put it last, and exactly one per pipeline.[/b] A flush mid-frame would let
## a dense slot cached by an earlier system point at a different entity by the
## time a later system reads it — a use-after-free that does not crash but
## silently yields wrong data. A second reaper elsewhere in the list breaks the
## same guarantee.
##
## It deliberately does NOT declare [member EcsSystem.requires_time]: entities
## marked for destruction before a pause must still be cleaned up — otherwise
## they hang in the queue and in every store for the whole time the game is
## paused.
##
## [b]How to react to deaths[/b]: enable
## [member EcsComponentStore.track_changes] on the stores you care about and
## register your reader IMMEDIATELY AFTER this system. By then `added_entities`
## holds everything that appeared this frame and `removed_entities` holds
## everything that died; when done, call [method EcsWorld.clear_change_logs].

## How many entities were destroyed in the last [method execute]. Handy for
## telemetry and for triggering death effects or sounds.
var last_reaped: int = 0

## How many entities have been destroyed in total since the system was created.
var total_reaped: int = 0

var _world: EcsWorld


func _init(world: EcsWorld = null, system_display_name: String = "Reaper") -> void:
	system_name = system_display_name
	writes_world_structure = true
	complete_access_metadata()
	_world = world


## The world is usually passed to [method _init]. This override also accepts it
## from a context object that has a `world` property — so both assembly styles
## work.
func setup(world: EcsWorld, context) -> void:
	if _world == null:
		_world = world
	if _world == null and context != null and context.get(&"world") != null:
		_world = context.get(&"world")
	if _world == null:
		push_error("EcsReaperSystem: no world — pass it to _init() or setup()")


func execute(_delta: float) -> void:
	if _world == null:
		return
	last_reaped = _world.flush_destroy_queue()
	total_reaped += last_reaped
