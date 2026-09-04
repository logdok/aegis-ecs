class_name AngleMath
extends RefCounted

## Helper functions for working with angles — everything needed to smoothly turn
## something toward a desired direction.
##
## An independent module: it does not use ECS and can be removed from the add-on
## if you do not need it.

## Moves [param current] toward [param desired] by no more than [param max_step],
## always along the shortest path around the circle.
##
## Why this is not trivial: the naive
## `current += clamp(desired - current, -max_step, max_step)` breaks at the ±PI
## crossover. If current = 3.1 rad and desired = -3.1 rad, the "straight"
## difference is -6.2 rad, even though the shortest path between those angles is
## only 0.08 rad the OTHER way. [method @GlobalScope.wrapf] with a range of
## (-PI, PI) brings the difference to its shortest equivalent before the step
## clamp.
static func approach(current: float, desired: float, max_step: float) -> float:
	return current + clampf(wrapf(desired - current, -PI, PI), -max_step, max_step)


## The absolute shortest angular distance between two angles, in radians (always
## non-negative). Needed where only "how far" matters, not "which way" — for
## example, when checking whether something is aimed accurately enough at a
## target before acting.
static func shortest_delta(from_angle: float, to_angle: float) -> float:
	return absf(wrapf(to_angle - from_angle, -PI, PI))
