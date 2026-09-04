class_name SimulationClock
extends RefCounted

## Аккумулятор фиксированного шага с масштабом времени — детерминизм, который
## переживает ускорение.
##
## Соглашение библиотеки о паузе (шаг нулевой длины) ничего не говорит о
## РАЗМЕРЕ шага, а передавать сырую дельту кадра прямо в симуляцию допустимо
## только пока эта дельта мала. Как только игрок получает возможность ускорить
## время, это перестаёт работать: при 50x кадр в 16 мс превращается в шаг в
## 800 мс, и всё, что продвигается по порогу — клетка, делящаяся в возрасте 10,
## снаряд, проверяющий, не пролетел ли он мимо цели, кулдаун — перепрыгивает
## сразу через несколько порогов за одно обновление. Симуляция не просто идёт
## быстрее, она даёт ДРУГОЙ результат, и на более медленной машине — снова
## другой.
##
## Фиксированный шаг убирает частоту кадров из уравнения. Часы накапливают
## реальное время, умножают его на [member time_scale] и сообщают, сколько
## одинаковых отрезков [member fixed_step] в накопленное поместилось. Каждый
## отрезок одинаков независимо от машины и настройки скорости, поэтому
## результат воспроизводим.
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
##     # Презентация выполняется один раз на отрисованный кадр, каким бы ни был
##     # масштаб времени -- и работает даже при steps == 0, что и держит
##     # поставленную на паузу игру нарисованной.
##     scheduler.execute_phase(PHASE_PRESENTATION, delta)
## [/codeblock]
##
## [b]Обратите внимание на две разные дельты.[/b] Фазы симуляции получают
## [member fixed_step], презентация — реальную дельту кадра. Прогонять весь
## конвейер через цикл суб-шагов означало бы N раз за кадр делать работу
## рендера без всякой пользы.
##
## Если фазы не используются, эквивалент для одной фазы:
## [codeblock]
## var steps: int = clock.advance(delta)
## if steps == 0:
##     scheduler.execute_all(0.0)          # пауза: только системы без requires_time
## else:
##     for i in steps:
##         scheduler.execute_all(clock.fixed_step)
## [/codeblock]

## Длина одного отрезка симуляции, в секундах. 1/60 — хороший вариант по
## умолчанию; более медленной симуляции подойдёт 1/30, и это вдвое сократит
## работу.
var fixed_step: float = 1.0 / 60.0:
	set(value):
		fixed_step = maxf(value, 0.000001)

## Множитель реального времени. 0 замораживает симуляцию, 1 — реальное время,
## 50 — быстрая перемотка. Отрицательные значения считаются нулём.
var time_scale: float = 1.0

## Верхняя граница числа отрезков, которые может выдать один [method advance].
##
## Это запредохранитель от «спирали смерти». Если один кадр оказался медленным,
## в аккумуляторе скопилось больше времени обычного; прогнать всё накопленное
## сделает этот кадр ещё медленнее, что накопит ещё больше. Сверх этого числа
## излишек ОТБРАСЫВАЕТСЯ — симуляция ненадолго идёт в замедленном темпе вместо
## того, чтобы заклиниться. Поднимите значение, чтобы терпеть более крупные
## подвисания, снизьте — чтобы ограничить худший кадр.
var max_substeps: int = 8

## Замораживает часы, не теряя ни аккумулятор, ни масштаб времени.
var paused: bool = false

## Сколько секунд симуляции прошло с последнего [method reset]. Растёт ровно на
## `fixed_step` за отрезок, поэтому значение точное, а не дрейфующее.
var elapsed_simulated: float = 0.0

## Сколько отрезков выдано всего с последнего [method reset].
var total_substeps: int = 0

## Сколько отрезков отброшено предохранителем [member max_substeps] с
## последнего [method reset]. Устойчивый рост означает, что симуляция не
## успевает за запрошенным [member time_scale].
var dropped_substeps: int = 0

var _accumulator: float = 0.0
var _last_substeps: int = 0


## Принимает один реальный кадр и возвращает, сколько фиксированных отрезков
## нужно выполнить сейчас. Вызывать ровно один раз за кадр.
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


## Сколько отрезков вернул последний [method advance].
func get_last_substeps() -> int:
	return _last_substeps


## Доля отрезка, сейчас лежащая в аккумуляторе неизрасходованной, в [0, 1).
##
## Это коэффициент интерполяции для плавного рендера: рисуйте движущийся объект
## как `previous_position.lerp(current_position, clock.get_alpha())`, и он
## перестанет выглядеть ступенчатым, когда частота симуляции ниже частоты
## кадров.
func get_alpha() -> float:
	return clampf(_accumulator / fixed_step, 0.0, 1.0)


## True, пока предохранитель отбрасывает время, то есть запрошенный масштаб
## времени превышает то, что машина способна отсимулировать.
func is_saturated() -> bool:
	return _last_substeps >= max_substeps


## Сколько секунд симуляции производится за секунду реального времени при
## текущих настройках. Полезно для HUD, который показывает фактическую (а не
## запрошенную) скорость.
func get_effective_time_scale(real_delta: float) -> float:
	if real_delta <= 0.0:
		return 0.0
	return float(_last_substeps) * fixed_step / real_delta


## Очищает аккумулятор и все счётчики. Вызывайте при перезапуске уровня, чтобы
## долгое подвисание перед сбросом не выплеснуло отрезки в новый забег.
func reset() -> void:
	_accumulator = 0.0
	_last_substeps = 0
	elapsed_simulated = 0.0
	total_substeps = 0
	dropped_substeps = 0
