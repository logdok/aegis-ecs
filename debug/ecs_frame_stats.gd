class_name EcsFrameStats
extends RefCounted

## Turns a window of recorded frames into answers.
##
## A single frame's numbers are noise: one OS stall inside one system's
## measurement window and the reading is meaningless. What to look at is the
## distribution — the typical cost, what most frames stay under, the worst case —
## and, above all, [b]which system is responsible for the spikes[/b].
##
## A live view cannot answer the last question at all, and here it is solved
## automatically: for each frame that ran long, the amount by which a system
## exceeded its OWN median is attributed to that system, and the totals are
## ranked. Instead of staring at flicker and guessing, you get
## "MissileSpatialIndex accounts for 71% of the excess in slow frames".
##
## [method analyse] is a cold operation: it sorts the window per system. Call it
## when you are about to read the results (a panel refresh, a report), not every
## frame.
##
## [codeblock]
## var stats := EcsFrameStats.new()
## stats.analyse(recorder)
## print(stats.get_frame_median_usec(), stats.get_frame_p95_usec())
## for rank in stats.get_spike_contributor_count():
##     var i: int = stats.get_spike_contributor(rank)
##     print(recorder.get_system_name(i), stats.get_system_excess_share(i))
## [/codeblock]

## A frame counts as a spike when it costs this many times the median.
var spike_factor: float = 1.5

## The percentile reported as "what most frames stay under".
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


## Recomputes every aggregate over the recorder's current window.
## Returns false when there is nothing to analyse yet.
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

	# Resolve the ring order once. Everything below indexes the flat buffers
	# arithmetically: over system_count x frame_count cells, a method call per
	# cell would cost more than all the rest of the analysis.
	var ring_capacity: int = recorder.frame_capacity
	var oldest: int = recorder.get_oldest_slot()
	var slots: PackedInt32Array = _slots
	for index in _frame_count:
		slots[index] = (oldest + index) % ring_capacity

	var timings: PackedFloat32Array = recorder.get_timings_unsafe()
	var statuses: PackedByteArray = recorder.get_status_unsafe()
	var stride: int = _system_count
	var executed_status: int = EcsFrameRecorder.Status.EXECUTED

	# --- per-frame distribution -------------------------------------------
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

	# --- per-system distribution ----------------------------------------
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

	# --- spike attribution ----------------------------------------------
	# Each system is charged exactly the amount by which it exceeded its OWN
	# median, summed over the slowest frames. A system that is simply expensive
	# every frame contributes nothing here; one that occasionally explodes
	# contributes everything. That distinction is the whole point.
	#
	# The slow TAIL is analysed (frames above p95), not "frames above a multiple
	# of the median". A window can be perfectly healthy and still have a slowest
	# 5% worth explaining, and that question makes sense even when nothing is
	# broken. Whether the window is actually unhealthy is a separate signal:
	# get_spike_frame_count(), which does use the multiple.
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


# --- per-frame results ------------------------------------------------------

## The average ECS time per frame over the window.
func get_frame_average_usec() -> float:
	return _frame_avg


## The typical frame. When estimating cost, prefer this to the mean: a single
## stall drags the mean along, the median not.
func get_frame_median_usec() -> float:
	return _frame_median


## What most frames stay under (the 95th percentile by default). This is the
## number to compare against the frame budget — the mean hides exactly the
## frames that cause the hitches.
func get_frame_p95_usec() -> float:
	return _frame_high


func get_frame_max_usec() -> float:
	return _frame_max


func get_frame_min_usec() -> float:
	return _frame_min


## The ring slot with the most expensive frame in the window — so you can
## dissect exactly that one. -1 if the window is empty.
func get_worst_frame_slot() -> int:
	return _worst_slot


## How many frames in the window exceeded the median by [member spike_factor].
func get_spike_frame_count() -> int:
	return _spike_count


## The fraction of the window in which frames ran long, as a percentage.
func get_spike_frame_percent() -> float:
	if _frame_count <= 0:
		return 0.0
	return float(_spike_count) / float(_frame_count) * 100.0


## The ratio of the worst frame to the typical one. Above ~2 it is a noticeable
## hitch, even if the average looks fine.
func get_spike_ratio() -> float:
	if _frame_median <= 0.0:
		return 0.0
	return _frame_max / _frame_median


# --- per-system results ---------------------------------------------------

func get_system_average_usec(index: int) -> float:
	return _avg[index]


func get_system_median_usec(index: int) -> float:
	return _median[index]


func get_system_p95_usec(index: int) -> float:
	return _high[index]


func get_system_max_usec(index: int) -> float:
	return _max[index]


## The fraction of all ECS time over the window, as a percentage.
func get_system_share_percent(index: int) -> float:
	return _share[index]


## The frames in which this system actually ran (rather than being paused,
## disabled or in a disabled phase).
func get_system_executed_frames(index: int) -> int:
	return _executed_frames[index]


## How stable a system is: the max divided by the median. A value near 1 means an
## even cost every frame; a large value means it occasionally explodes, which is
## what feels like a hitch.
##
## The median is bounded below by one microsecond, so a system that is usually
## free and occasionally costs 46 us reports 46x rather than dividing by zero and
## pretending to be perfectly stable — which would be the exact opposite of the
## truth.
func get_system_volatility(index: int) -> float:
	return _max[index] / maxf(_median[index], 1.0)


## How many microseconds this system added above its own median, summed over the
## slow frames.
func get_system_excess_usec(index: int) -> float:
	return _excess[index]


## The same as a fraction of all the excess in slow frames. This is the
## "who is to blame for the hitches" number.
func get_system_excess_share(index: int) -> float:
	if _total_excess <= 0.0:
		return 0.0
	return _excess[index] / _total_excess * 100.0


func get_total_excess_usec() -> float:
	return _total_excess


## How many frames the excess was spread across (the slow tail).
func get_attributed_frame_count() -> int:
	return _attributed_frames


# --- ranking of the culprits --------------------------------------------

## Systems ordered by their contribution to slow frames, worst first.
func get_spike_contributor_count() -> int:
	return _ranking.size()


func get_spike_contributor(rank: int) -> int:
	return _ranking[rank]


# --- the world over the window -----------------------------------------

func get_live_min() -> int:
	return _live_min


func get_live_max() -> int:
	return _live_max


## How many times the world's capacity changed over the window.
func get_capacity_change_count() -> int:
	return _capacity_changes


## The largest destroy queue seen at the end of a frame. Any value above zero
## means the queue is not being drained where it should be.
func get_peak_pending_destroy() -> int:
	return _peak_pending


func _percentile(sorted_values: PackedFloat32Array, quantile: float) -> float:
	var size: int = sorted_values.size()
	if size == 0:
		return 0.0
	var index: int = clampi(int(float(size) * quantile), 0, size - 1)
	return sorted_values[index]


## Insertion sort over an index array: there are only a few systems (dozens) and
## this is all cold path, so a simple stable sort keeps the registration order on
## ties — which reads better than an arbitrary one.
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
