class_name AngleMath
extends RefCounted

## Вспомогательные функции для работы с углами — всё, что нужно, чтобы плавно
## доворачивать что-либо к желаемому направлению.
##
## Независимый модуль: не использует ECS и может быть удалён из аддона, если
## не нужен.

## Сдвигает [param current] в сторону [param desired] не более чем на
## [param max_step], всегда кратчайшим путём по кругу.
##
## Почему это нетривиально: наивное
## `current += clamp(desired - current, -max_step, max_step)` ломается на
## переходе через ±PI. Если current = 3.1 рад, а desired = -3.1 рад, разница
## "в лоб" равна -6.2 рад, хотя кратчайший путь между этими углами — всего
## 0.08 рад в ДРУГУЮ сторону. [method @GlobalScope.wrapf] с диапазоном
## (-PI, PI) как раз приводит разницу к кратчайшему эквиваленту, прежде чем
## её ограничат шагом.
static func approach(current: float, desired: float, max_step: float) -> float:
	return current + clampf(wrapf(desired - current, -PI, PI), -max_step, max_step)


## Абсолютная кратчайшая угловая дистанция между двумя углами, в радианах
## (всегда неотрицательная). Нужна там, где важно только "насколько далеко",
## а не "в какую сторону" — например, при проверке, достаточно ли точно
## что-либо наведено на цель, прежде чем действовать.
static func shortest_delta(from_angle: float, to_angle: float) -> float:
	return absf(wrapf(to_angle - from_angle, -PI, PI))
