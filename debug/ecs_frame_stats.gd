class_name EcsFrameStats
extends RefCounted

## Превращает окно записанных кадров в ответы.
##
## Цифры одного кадра — это шум: достаточно одной заминки ОС внутри окна замера
## одной системы, и показание бессмысленно. Смотреть стоит на распределение —
## типичную стоимость, ту, под которой остаётся большинство кадров, худший
## случай — и, главное, на то, [b]какая система отвечает за всплески[/b].
##
## На последний вопрос живой показ ответить не способен в принципе, а здесь он
## решается автоматически: для каждого затянувшегося кадра превышение над
## СОБСТВЕННОЙ медианой системы приписывается этой системе, и итоги ранжируются.
## Вместо того чтобы смотреть на мельтешение и гадать, вы получаете
## «MissileSpatialIndex отвечает за 71% избытка в медленных кадрах».
##
## [method analyse] — холодная операция: она сортирует окно по каждой системе.
## Вызывайте её, когда собираетесь читать результаты (обновление панели, отчёт),
## а не каждый кадр.
##
## [codeblock]
## var stats := EcsFrameStats.new()
## stats.analyse(recorder)
## print(stats.get_frame_median_usec(), stats.get_frame_p95_usec())
## for rank in stats.get_spike_contributor_count():
##     var i: int = stats.get_spike_contributor(rank)
##     print(recorder.get_system_name(i), stats.get_system_excess_share(i))
## [/codeblock]

## Кадр считается всплеском, когда стоит во столько раз больше медианного.
var spike_factor: float = 1.5

## Процентиль, сообщаемый как «под чем остаётся большинство кадров».
var high_percentile: float = 0.95

var _system_count: int = 0
var _frame_count: int = 0

var _avg: PackedFloat32Array = PackedFloat32Array()
var _median: PackedFloat32Array = PackedFloat32Array()
var _high: PackedFloat32Array = PackedFloat32Array()
var _max: PackedFloat32Array = PackedFloat32Array()
var _share: PackedFloat32Array = PackedFloat32Array()
var _excess: PackedFloat32Array = PackedFloat32Array()
var _executed_frames: PackedInt32Array = PackedInt32Array()

var _scratch: PackedFloat32Array = PackedFloat32Array()
var _slots: PackedInt32Array = PackedInt32Array()
var _ranking: PackedInt32Array = PackedInt32Array()

var _frame_avg: float = 0.0
var _frame_median: float = 0.0
var _frame_high: float = 0.0
var _frame_max: float = 0.0
var _frame_min: float = 0.0
var _worst_slot: int = -1
var _spike_count: int = 0
var _attributed_frames: int = 0
var _total_excess: float = 0.0

var _live_min: int = 0
var _live_max: int = 0
var _capacity_changes: int = 0
var _peak_pending: int = 0
var _analysed: bool = false


## Пересчитывает все агрегаты по текущему окну рекордера.
## Возвращает false, когда анализировать ещё нечего.
func analyse(recorder: EcsFrameRecorder) -> bool:
	_analysed = false
	if recorder == null or not recorder.is_configured():
		return false
	_frame_count = recorder.get_frame_count()
	_system_count = recorder.system_count
	if _frame_count <= 0 or _system_count <= 0:
		return false

	_avg.resize(_system_count)
	_median.resize(_system_count)
	_high.resize(_system_count)
	_max.resize(_system_count)
	_share.resize(_system_count)
	_excess.resize(_system_count)
	_executed_frames.resize(_system_count)
	_excess.fill(0.0)
	_executed_frames.fill(0)
	_scratch.resize(_frame_count)
	_slots.resize(_frame_count)

	# Порядок кольца разрешаем один раз. Всё ниже индексирует плоские буферы
	# арифметически: при system_count x frame_count ячейках вызов метода на каждую
	# стоил бы больше, чем весь остальной анализ.
	var ring_capacity: int = recorder.frame_capacity
	var oldest: int = recorder.get_oldest_slot()
	var slots: PackedInt32Array = _slots
	for index in _frame_count:
		slots[index] = (oldest + index) % ring_capacity

	var timings: PackedFloat32Array = recorder.get_timings_unsafe()
	var statuses: PackedByteArray = recorder.get_status_unsafe()
	var stride: int = _system_count
	var executed_status: int = EcsFrameRecorder.Status.EXECUTED

	# --- распределение по кадрам ---------------------------------------------
	var frame_sum: float = 0.0
	_frame_max = -1.0
	_frame_min = INF
	_worst_slot = -1
	_live_min = 2147483647
	_live_max = 0
	_capacity_changes = 0
	_peak_pending = 0
	var previous_capacity: int = -1

	for index in _frame_count:
		var slot: int = slots[index]
		var total: float = recorder.get_frame_total_usec(slot)
		_scratch[index] = total
		frame_sum += total
		if total > _frame_max:
			_frame_max = total
			_worst_slot = slot
		if total < _frame_min:
			_frame_min = total

		var live: int = recorder.get_frame_live_count(slot)
		_live_min = mini(_live_min, live)
		_live_max = maxi(_live_max, live)
		_peak_pending = maxi(_peak_pending, recorder.get_frame_pending_destroy(slot))
		var capacity_now: int = recorder.get_frame_world_capacity(slot)
		if previous_capacity != -1 and capacity_now != previous_capacity:
			_capacity_changes += 1
		previous_capacity = capacity_now

	_frame_avg = frame_sum / float(_frame_count)
	_scratch.sort()
	_frame_median = _percentile(_scratch, 0.5)
	_frame_high = _percentile(_scratch, high_percentile)
	if _frame_min == INF:
		_frame_min = 0.0

	# --- распределение по системам -------------------------------------------
	for system in _system_count:
		var sum: float = 0.0
		var peak: float = 0.0
		var executed: int = 0
		for index in _frame_count:
			var cell: int = slots[index] * stride + system
			var value: float = timings[cell]
			_scratch[index] = value
			sum += value
			if value > peak:
				peak = value
			if statuses[cell] == executed_status:
				executed += 1
		_avg[system] = sum / float(_frame_count)
		_max[system] = peak
		_executed_frames[system] = executed
		_share[system] = (sum / frame_sum * 100.0) if frame_sum > 0.0 else 0.0
		_scratch.sort()
		_median[system] = _percentile(_scratch, 0.5)
		_high[system] = _percentile(_scratch, high_percentile)

	# --- атрибуция всплесков --------------------------------------------------
	# Каждой системе вменяется ровно то, насколько она превысила СВОЮ СОБСТВЕННУЮ
	# медиану, просуммированное по самым медленным кадрам. Система, которая просто
	# дорога каждый кадр, не вносит сюда ничего; та, что изредка взрывается,
	# вносит всё. В этом различии и весь смысл.
	#
	# Разбирается медленный ХВОСТ (кадры выше p95), а не «кадры выше кратного
	# медиане». Окно может быть совершенно здоровым и всё равно иметь самые
	# медленные 5%, которые стоит объяснить, и этот вопрос осмыслен даже когда
	# ничего не сломано. А нездорово ли окно на самом деле — отдельный сигнал:
	# get_spike_frame_count(), который как раз использует кратность.
	var tail_threshold: float = _frame_high
	var spike_threshold: float = _frame_median * spike_factor
	_spike_count = 0
	_total_excess = 0.0
	_attributed_frames = 0
	for index in _frame_count:
		var slot: int = slots[index]
		var total: float = recorder.get_frame_total_usec(slot)
		if total > spike_threshold:
			_spike_count += 1
		if total < tail_threshold:
			continue
		_attributed_frames += 1
		var base: int = slot * stride
		for system in _system_count:
			var over: float = timings[base + system] - _median[system]
			if over > 0.0:
				_excess[system] += over
				_total_excess += over

	_ranking.resize(_system_count)
	for system in _system_count:
		_ranking[system] = system
	_sort_ranking_by_excess()
	_analysed = true
	return true


func is_analysed() -> bool:
	return _analysed


func get_frame_count() -> int:
	return _frame_count


func get_system_count() -> int:
	return _system_count


# --- результаты по кадру ------------------------------------------------------

## Среднее время ECS на кадр за окно.
func get_frame_average_usec() -> float:
	return _frame_avg


## Типичный кадр. Оценивая стоимость, предпочитайте эту величину среднему:
## среднее утягивает за собой одна-единственная заминка, медиану — нет.
func get_frame_median_usec() -> float:
	return _frame_median


## То, под чем остаётся большинство кадров (по умолчанию 95-й процентиль).
## Именно это число сравнивают с бюджетом кадра — среднее прячет как раз те
## кадры, которые и дают рывки.
func get_frame_p95_usec() -> float:
	return _frame_high


func get_frame_max_usec() -> float:
	return _frame_max


func get_frame_min_usec() -> float:
	return _frame_min


## Слот кольца с самым дорогим кадром окна — чтобы разобрать по полочкам именно
## его. -1, если окно пусто.
func get_worst_frame_slot() -> int:
	return _worst_slot


## Сколько кадров окна превысили медиану в [member spike_factor] раз.
func get_spike_frame_count() -> int:
	return _spike_count


## Доля окна, в которой кадры затянулись, в процентах.
func get_spike_frame_percent() -> float:
	if _frame_count <= 0:
		return 0.0
	return float(_spike_count) / float(_frame_count) * 100.0


## Отношение худшего кадра к типичному. Выше ~2 — это заметный рывок, даже если
## среднее выглядит прилично.
func get_spike_ratio() -> float:
	if _frame_median <= 0.0:
		return 0.0
	return _frame_max / _frame_median


# --- результаты по системам ---------------------------------------------------

func get_system_average_usec(index: int) -> float:
	return _avg[index]


func get_system_median_usec(index: int) -> float:
	return _median[index]


func get_system_p95_usec(index: int) -> float:
	return _high[index]


func get_system_max_usec(index: int) -> float:
	return _max[index]


## Доля от всего времени ECS за окно, в процентах.
func get_system_share_percent(index: int) -> float:
	return _share[index]


## Кадры, в которых эта система реально выполнялась (а не была на паузе,
## выключена или в выключенной фазе).
func get_system_executed_frames(index: int) -> int:
	return _executed_frames[index]


## Насколько система стабильна: максимум, делённый на медиану. Значение около 1
## означает ровную стоимость каждый кадр; большое — что она изредка взрывается,
## а это и есть то, что ощущается как рывок.
##
## Медиана снизу ограничена одной микросекундой, поэтому система, обычно
## бесплатная и изредка стоящая 46 мкс, отчитается как 46x, а не поделит на ноль
## и не притворится идеально стабильной — что было бы прямо противоположно правде.
func get_system_volatility(index: int) -> float:
	return _max[index] / maxf(_median[index], 1.0)


## Сколько микросекунд эта система добавила сверх собственной медианы,
## просуммировано по медленным кадрам.
func get_system_excess_usec(index: int) -> float:
	return _excess[index]


## То же самое как доля от всего избытка в медленных кадрах. Это и есть число
## «кто виноват в рывках».
func get_system_excess_share(index: int) -> float:
	if _total_excess <= 0.0:
		return 0.0
	return _excess[index] / _total_excess * 100.0


func get_total_excess_usec() -> float:
	return _total_excess


## По скольким кадрам разносился избыток (медленный хвост).
func get_attributed_frame_count() -> int:
	return _attributed_frames


# --- ранжирование виновников --------------------------------------------------

## Системы, упорядоченные по вкладу в медленные кадры, худшие первыми.
func get_spike_contributor_count() -> int:
	return _ranking.size()


func get_spike_contributor(rank: int) -> int:
	return _ranking[rank]


# --- мир за окно --------------------------------------------------------------

func get_live_min() -> int:
	return _live_min


func get_live_max() -> int:
	return _live_max


## Сколько раз за окно менялась ёмкость мира.
func get_capacity_change_count() -> int:
	return _capacity_changes


## Наибольшая очередь уничтожения, замеченная в конце кадра. Любое значение
## больше нуля означает, что очередь не спорожняется там, где должна.
func get_peak_pending_destroy() -> int:
	return _peak_pending


func _percentile(sorted_values: PackedFloat32Array, quantile: float) -> float:
	var size: int = sorted_values.size()
	if size == 0:
		return 0.0
	var index: int = clampi(int(float(size) * quantile), 0, size - 1)
	return sorted_values[index]


## Сортировка вставками по массиву индексов: систем немного (десятки), и всё это
## холодный путь, поэтому простая устойчивая сортировка сохраняет порядок
## регистрации при равенстве — так читается лучше, чем при произвольном.
func _sort_ranking_by_excess() -> void:
	var ranking: PackedInt32Array = _ranking
	for i in range(1, ranking.size()):
		var current: int = ranking[i]
		var value: float = _excess[current]
		var j: int = i - 1
		while j >= 0 and _excess[ranking[j]] < value:
			ranking[j + 1] = ranking[j]
			j -= 1
		ranking[j + 1] = current
