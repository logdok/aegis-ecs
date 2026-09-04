extends PanelContainer

## The visual side of [EcsInspector]. Optional and removable.
##
## This file (and the folder it lives in) can be deleted or excluded from the
## export preset with nothing else touched: [EcsInspector] resolves it by path at
## runtime and simply keeps collecting data with no interface when the file is
## gone. Nothing in the library references it by class name — which is exactly
## why it has no `class_name` of its own.
##
## [b]It leads with collected statistics, not live numbers.[/b] A value that
## changes sixty times a second is impossible to read, and the frame you are
## looking at is almost never the interesting one. So the systems table shows the
## distribution over the window — the typical cost, the worst case, how uneven it
## is — and the section below it names the systems responsible for the slow
## frames. The current frame is there too, at the top, on one line: worth a
## glance, no more.
##
## Built entirely in code, so it is a single file with no scene dependency.
## Redrawn at a fixed low rate regardless of the frame rate: updating this panel
## costs more than the simulation it measures, and nothing here changes fast
## enough to warrant drawing it every frame.

const COLOR_TEXT: String = "#d6dae0"
const COLOR_DIM: String = "#7a828c"
const COLOR_ACCENT: String = "#8ab4f8"
const COLOR_GOOD: String = "#7fd18c"
const COLOR_WARN: String = "#e5c07b"
const COLOR_BAD: String = "#e08b7b"

## The redraw rate. Collection underneath it still runs every frame.
const REFRESH_HZ: float = 6.0

## Below this width the layout collapses into a single narrow column.
const COMPACT_WIDTH: float = 430.0

var _inspector: EcsInspector
var _body: VBoxContainer
var _scroll: ScrollContainer
var _title_label: Label
var _sections: Dictionary = {}
var _time_since_refresh: float = 0.0
var _font: SystemFont
var _compact: bool = false
var _show_worst_frame: bool = true


func _init() -> void:
	name = "EcsInspectorPanel"
	# Only the minimum WIDTH is set. The height and the final width come from the
	# container the host placed the panel in, so the same panel works both as a
	# small floating block and as a full-height side panel, and no two variants
	# are needed for that.
	custom_minimum_size = Vector2(280, 0)
	size_flags_horizontal = Control.SIZE_EXPAND_FILL
	size_flags_vertical = Control.SIZE_EXPAND_FILL
	mouse_filter = Control.MOUSE_FILTER_STOP


func _ready() -> void:
	_font = SystemFont.new()
	# Whichever the platform has; the last one is the generic fallback.
	_font.font_names = PackedStringArray([
		"Menlo", "SF Mono", "Consolas", "DejaVu Sans Mono", "Liberation Mono", "monospace",
	])

	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.06, 0.07, 0.09, 0.92)
	style.border_color = Color(0.20, 0.23, 0.28, 1.0)
	style.set_border_width_all(1)
	style.set_content_margin_all(8)
	style.set_corner_radius_all(4)
	add_theme_stylebox_override("panel", style)

	var root := VBoxContainer.new()
	root.add_theme_constant_override("separation", 4)
	add_child(root)

	root.add_child(_build_header())

	_scroll = ScrollContainer.new()
	_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	# On a touch screen a deadzone of 0 (the default) treats every tap with the
	# slightest finger movement as a scroll pan, so the [url] meta-clicks that
	# toggle a system never reach the RichTextLabel underneath. A few pixels of
	# slack lets a tap through while still scrolling on a real drag.
	_scroll.scroll_deadzone = 12
	root.add_child(_scroll)

	_body = VBoxContainer.new()
	_body.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_body.add_theme_constant_override("separation", 6)
	_scroll.add_child(_body)

	_add_section(&"summary", "Frame", true)
	_add_section(&"counters", "Counters", true)
	_add_section(&"systems", "Systems  (window statistics)", true)
	_add_section(&"spikes", "What makes the slow frames slow", true)
	_add_section(&"alerts", "Diagnostics", true)
	_add_section(&"worst", "Worst frame in the window", false)
	_add_section(&"world", "World and stores", false)

	# If bind() arrived before entering the tree, the drawing was deferred to here.
	_refresh()


## Called by [EcsInspector] right after the panel is created.
##
## It can arrive BEFORE `_ready()`: `add_child()` triggers `_ready()` only if the
## parent is already in the tree, and the host may assemble the panel in a
## detached container. So here the reference is only remembered, and the drawing
## is left to `_refresh()`, which knows how to do nothing while there are no
## sections yet.
func bind(inspector: EcsInspector) -> void:
	_inspector = inspector
	_refresh()


func _process(delta: float) -> void:
	# There is no point redrawing an invisible panel: `_process` runs on hidden
	# nodes too, so the check is mandatory, otherwise a hidden panel would keep
	# costing as much as an open one.
	if _inspector == null or not is_visible_in_tree():
		return
	_time_since_refresh += delta
	if _time_since_refresh < 1.0 / REFRESH_HZ:
		return
	_time_since_refresh = 0.0
	_refresh()


# --- construction ------------------------------------------------------------

func _build_header() -> Control:
	var header := HBoxContainer.new()
	header.add_theme_constant_override("separation", 4)

	_title_label = Label.new()
	_title_label.text = "AEGIS ECS INSPECTOR"
	_title_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_title_label.add_theme_color_override("font_color", Color(COLOR_ACCENT))
	header.add_child(_title_label)

	var report_button := Button.new()
	report_button.text = "log"
	report_button.tooltip_text = "Print the full report to the console"
	report_button.focus_mode = Control.FOCUS_NONE
	report_button.pressed.connect(_on_report_pressed)
	header.add_child(report_button)

	var save_button := Button.new()
	save_button.text = "save"
	save_button.tooltip_text = "Write report.txt / .json / frames.csv to user://"
	save_button.focus_mode = Control.FOCUS_NONE
	save_button.pressed.connect(_on_save_pressed)
	header.add_child(save_button)

	return header


## A collapsible section is its own card: a rounded background with a toggle
## header inside and a body of formatted text.
##
## One label per section, not a widget per row, so an update is a few string
## assignments rather than rebuilding a node tree.
func _add_section(key: StringName, title: String, expanded: bool) -> void:
	var card := PanelContainer.new()
	card.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var card_style := StyleBoxFlat.new()
	card_style.bg_color = Color(0.10, 0.11, 0.14, 0.85)
	card_style.set_corner_radius_all(6)
	card_style.set_content_margin_all(8)
	card.add_theme_stylebox_override("panel", card_style)
	_body.add_child(card)

	var container := VBoxContainer.new()
	container.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	container.add_theme_constant_override("separation", 4)
	card.add_child(container)

	var toggle := Button.new()
	toggle.text = ("▾ " if expanded else "▸ ") + title
	toggle.alignment = HORIZONTAL_ALIGNMENT_LEFT
	toggle.flat = true
	toggle.focus_mode = Control.FOCUS_NONE
	toggle.add_theme_color_override("font_color", Color(COLOR_DIM))
	container.add_child(toggle)

	var content := RichTextLabel.new()
	content.bbcode_enabled = true
	content.fit_content = true
	content.scroll_active = false
	# Text selection and a meta tap compete for the same gesture on a touch
	# screen, and a tap that starts a selection never emits meta_clicked. Drag
	# to select is a pointer affordance anyway, so it is dropped where there is
	# no pointer.
	content.selection_enabled = not DisplayServer.is_touchscreen_available()
	content.visible = expanded
	content.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	content.add_theme_font_override("normal_font", _font)
	content.add_theme_font_override("mono_font", _font)
	content.add_theme_font_size_override("normal_font_size", 12)
	content.meta_clicked.connect(_on_meta_clicked)
	container.add_child(content)

	toggle.pressed.connect(func() -> void:
		content.visible = not content.visible
		toggle.text = ("▾ " if content.visible else "▸ ") + title)

	_sections[key] = {"title": title, "toggle": toggle, "content": content, "card": card}


func _set_section(key: StringName, text: String, visible_section: bool = true) -> void:
	var section: Dictionary = _sections[key]
	# Hide the whole card: hiding only its content would leave an empty rounded
	# background on screen.
	section["card"].visible = visible_section
	if visible_section:
		section["content"].text = text


# --- refresh ----------------------------------------------------------------

func _refresh() -> void:
	if _sections.is_empty():
		# _ready() has not built the sections yet: nothing to draw, and no reason to.
		return
	if _inspector == null:
		_set_section(&"summary", _dim("Not bound to an inspector."))
		return
	_compact = size.x > 0.0 and size.x < COMPACT_WIDTH

	var recorder: EcsFrameRecorder = _inspector.recorder
	var stats: EcsFrameStats = _inspector.stats
	if not recorder.is_configured() or recorder.get_frame_count() == 0:
		_set_section(&"summary", _dim("Waiting for the first captured frame…"))
		return

	_refresh_summary(recorder, stats)
	_refresh_counters()
	_refresh_systems(recorder, stats)
	_refresh_spikes(recorder, stats)
	_refresh_alerts()
	_refresh_worst(recorder, stats)
	_refresh_world(recorder, stats)


func _refresh_summary(recorder: EcsFrameRecorder, stats: EcsFrameStats) -> void:
	var newest: int = recorder.get_newest_slot()
	var wall: float = recorder.get_frame_wall_usec(newest)
	var ecs_now: float = recorder.get_frame_total_usec(newest)
	var lines: PackedStringArray = PackedStringArray()

	# One "right now" line, everything else is about the window.
	var fps: float = Engine.get_frames_per_second()
	lines.append("%s  %s   frame %s   ecs %s%s" % [
		_dim("now"), _value("%.0f fps" % fps),
		_value("%.2f ms" % (wall / 1000.0)),
		_value("%.2f ms" % (ecs_now / 1000.0)),
		_dim("  (%d entities)" % recorder.get_frame_live_count(newest)),
	])

	if not stats.is_analysed():
		_set_section(&"summary", "\n".join(lines))
		return

	var budget: float = _inspector.diagnostics.frame_budget_usec
	var p95: float = stats.get_frame_p95_usec()
	var p95_color: String = COLOR_BAD if p95 > budget else COLOR_GOOD
	lines.append("")
	lines.append("%s over %s frames" % [_dim("ECS cost"), _value(str(stats.get_frame_count()))])
	lines.append("  median %s   p95 %s   max %s" % [
		_value("%.2f ms" % (stats.get_frame_median_usec() / 1000.0)),
		"[color=%s]%.2f ms[/color]" % [p95_color, p95 / 1000.0],
		_value("%.2f ms" % (stats.get_frame_max_usec() / 1000.0)),
	])

	var ratio: float = stats.get_spike_ratio()
	var ratio_color: String = COLOR_BAD if ratio >= 2.0 else (COLOR_WARN if ratio >= 1.5 else COLOR_GOOD)
	lines.append("  worst is [color=%s]%.1fx[/color] the typical frame%s" % [
		ratio_color, ratio,
		_dim("   %d slow frames" % stats.get_spike_frame_count()),
	])

	var substeps: int = recorder.get_frame_substeps(newest)
	if substeps > 1:
		lines.append(_dim("  timings cover %d simulation substeps per frame" % substeps))
	_set_section(&"summary", "\n".join(lines))


func _refresh_counters() -> void:
	var sections: int = _inspector.get_counter_section_count()
	if sections == 0:
		_set_section(&"counters", "", false)
		return
	var lines: PackedStringArray = PackedStringArray()
	for index in sections:
		if index > 0:
			lines.append("")
		lines.append(_dim(_inspector.get_counter_section_title(index)))
		for row in _inspector.get_counter_section_rows(index):
			if row is Array and row.size() >= 2:
				lines.append("  %-22s %s" % [str(row[0]), _value(str(row[1]))])
	_set_section(&"counters", "\n".join(lines))


func _refresh_systems(recorder: EcsFrameRecorder, stats: EcsFrameStats) -> void:
	if not stats.is_analysed():
		_set_section(&"systems", _dim("collecting…"))
		return
	var lines: PackedStringArray = PackedStringArray()
	var can_toggle: bool = _inspector.mode >= EcsInspector.Mode.DEV

	if _compact:
		lines.append(_dim("%-20s %7s %6s" % ["system", "median", "share"]))
	else:
		lines.append(_dim("%-24s %8s %8s %8s %7s %7s" % ["system", "median", "p95", "max", "share", "spread"]))

	for index in stats.get_system_count():
		var raw_name: String = recorder.get_system_name(index)
		var label: String = raw_name
		if can_toggle:
			label = "[url=sys:%d]%s[/url]" % [index, raw_name]

		var share: float = stats.get_system_share_percent(index)
		var volatility: float = stats.get_system_volatility(index)
		var enabled: bool = _inspector.get_scheduler().is_system_enabled(index)
		var name_color: String = COLOR_TEXT if enabled else COLOR_DIM
		var padding: int = 20 if _compact else 24
		var pad: String = " ".repeat(maxi(padding - raw_name.length(), 1))

		if _compact:
			lines.append("[color=%s]%s[/color]%s %7d %5.1f%%" % [
				name_color, label, pad, int(stats.get_system_median_usec(index)), share])
		else:
			var spread_color: String = COLOR_WARN if volatility >= 5.0 else COLOR_DIM
			lines.append("[color=%s]%s[/color]%s %8d %8d %8d %6.1f%% [color=%s]%6.1fx[/color]" % [
				name_color, label, pad,
				int(stats.get_system_median_usec(index)),
				int(stats.get_system_p95_usec(index)),
				int(stats.get_system_max_usec(index)),
				share, spread_color, volatility,
			])
		if not enabled:
			lines[lines.size() - 1] += _dim("  off")

	if can_toggle:
		lines.append("")
		lines.append(_dim("click a system name to switch it off — the fastest way to find"))
		lines.append(_dim("out what a system is actually responsible for"))
	_set_section(&"systems", "\n".join(lines))


func _refresh_spikes(recorder: EcsFrameRecorder, stats: EcsFrameStats) -> void:
	if not stats.is_analysed() or stats.get_total_excess_usec() <= 0.0:
		_set_section(&"spikes", _dim("Nothing stands out: the slow frames are slow evenly."))
		return
	var lines: PackedStringArray = PackedStringArray()
	lines.append(_dim("excess over each system's own median, across the slowest %d frames"
		% stats.get_attributed_frame_count()))
	lines.append("")
	var listed: int = 0
	for rank in stats.get_spike_contributor_count():
		var index: int = stats.get_spike_contributor(rank)
		var excess_share: float = stats.get_system_excess_share(index)
		if stats.get_system_excess_usec(index) <= 0.0 or listed >= 5:
			break
		var bar: String = "█".repeat(clampi(int(excess_share / 5.0), 0, 20))
		var color: String = COLOR_BAD if excess_share >= 30.0 else COLOR_WARN
		lines.append("[color=%s]%5.1f%%[/color] %-24s %s" % [color, excess_share,
			recorder.get_system_name(index), "[color=%s]%s[/color]" % [color, bar]])
		lines.append(_dim("        median %d us, peaks at %d us (%.0fx)" % [
			int(stats.get_system_median_usec(index)),
			int(stats.get_system_max_usec(index)),
			stats.get_system_volatility(index)]))
		listed += 1
	_set_section(&"spikes", "\n".join(lines))


func _refresh_alerts() -> void:
	var findings: Array = _inspector.get_findings()
	if findings.is_empty():
		_set_section(&"alerts", "[color=%s]No issues detected.[/color]" % COLOR_GOOD)
		return
	var lines: PackedStringArray = PackedStringArray()
	for finding in findings:
		var color: String = COLOR_DIM
		match finding.severity:
			EcsDiagnostics.Finding.Severity.CRITICAL:
				color = COLOR_BAD
			EcsDiagnostics.Finding.Severity.WARNING:
				color = COLOR_WARN
		lines.append("[color=%s]%s[/color] %s %s" % [
			color, finding.severity_label(), _dim(finding.source), finding.title])
		if not finding.detail.is_empty():
			lines.append(_dim("    " + finding.detail))
		if not finding.hint.is_empty():
			lines.append("[color=%s]    → %s[/color]" % [COLOR_ACCENT, finding.hint])
		lines.append("")
	_set_section(&"alerts", "\n".join(lines))


func _refresh_worst(recorder: EcsFrameRecorder, stats: EcsFrameStats) -> void:
	if not _show_worst_frame or not stats.is_analysed():
		_set_section(&"worst", "", false)
		return
	var slot: int = stats.get_worst_frame_slot()
	if slot < 0:
		_set_section(&"worst", _dim("no frame recorded"))
		return
	var lines: PackedStringArray = PackedStringArray()
	var total: float = recorder.get_frame_total_usec(slot)
	lines.append(_dim("frame #%d — %.3f ms, %d entities" % [
		recorder.get_frame_id(slot), total / 1000.0, recorder.get_frame_live_count(slot)]))
	lines.append("")
	for index in recorder.system_count:
		var value: float = recorder.get_timing_usec(slot, index)
		var share: float = (value / total * 100.0) if total > 0.0 else 0.0
		var median: float = stats.get_system_median_usec(index)
		var marker: String = ""
		if value > median * 2.0 and value - median > 20.0:
			marker = "[color=%s]  ← %.0fx its median[/color]" % [COLOR_BAD, value / maxf(median, 1.0)]
		lines.append("%-24s %7d %5.1f%% %s%s" % [
			recorder.get_system_name(index), int(value), share,
			_dim("█".repeat(clampi(int(share / 4.0), 0, 20))), marker])
	_set_section(&"worst", "\n".join(lines))


func _refresh_world(recorder: EcsFrameRecorder, stats: EcsFrameStats) -> void:
	var world: EcsWorld = _inspector.get_world()
	if world == null:
		_set_section(&"world", "", false)
		return
	var lines: PackedStringArray = PackedStringArray()
	var load_factor: float = world.get_load_factor()
	var load_color: String = COLOR_BAD if load_factor >= 0.9 else (COLOR_WARN if load_factor >= 0.75 else COLOR_GOOD)
	lines.append("entities  %s [color=%s]%.0f%% full[/color]" % [
		_value("%d / %d" % [world.get_live_count(), world.capacity]), load_color, load_factor * 100.0])
	if stats.is_analysed():
		lines.append(_dim("  window range %d..%d, capacity changes %d, peak pending destroy %d" % [
			stats.get_live_min(), stats.get_live_max(),
			stats.get_capacity_change_count(), stats.get_peak_pending_destroy()]))
	lines.append("")
	lines.append(_dim("%-24s %8s %8s %6s" % ["store", "count", "capacity", "fill"]))
	for index in world.get_store_count():
		var store: EcsComponentStore = world.get_store_at(index)
		var capacity: int = maxi(store.get_capacity(), 1)
		var fill: float = float(store.count) / float(capacity) * 100.0
		var color: String = COLOR_BAD if fill >= 90.0 else COLOR_TEXT
		lines.append("[color=%s]%-24s %8d %8d %5.1f%%[/color]" % [
			color, store.get_debug_name().left(24), store.count, capacity, fill])

	var grids: Dictionary = _inspector.get_grids()
	if not grids.is_empty():
		lines.append("")
		lines.append(_dim("%-24s %8s %8s %6s" % ["grid", "entries", "cells", "flat"]))
		for grid_name in grids:
			var grid: UniformSpatialGrid = grids[grid_name]
			if grid == null:
				continue
			lines.append("%-24s %8d %8d %6s" % [
				String(grid_name).left(24), grid.get_entry_count(),
				grid.get_cell_count(), "yes" if grid.is_flat() else "no"])

	var clock: SimulationClock = _inspector.get_clock()
	if clock != null:
		lines.append("")
		lines.append("clock  scale %s  substeps %s  dropped %s" % [
			_value("%.1fx" % clock.time_scale),
			_value(str(clock.get_last_substeps())),
			_value(str(clock.dropped_substeps))])
	_set_section(&"world", "\n".join(lines))


# --- interaction ------------------------------------------------------------

func _on_meta_clicked(meta: Variant) -> void:
	var text: String = str(meta)
	if not text.begins_with("sys:"):
		return
	if _inspector == null or _inspector.mode < EcsInspector.Mode.DEV:
		return
	var index: int = int(text.substr(4))
	var scheduler: EcsScheduler = _inspector.get_scheduler()
	if index < 0 or index >= scheduler.get_system_count():
		return
	scheduler.set_system_enabled(index, not scheduler.is_system_enabled(index))
	_refresh()



func _on_report_pressed() -> void:
	if _inspector != null:
		_inspector.print_report()


func _on_save_pressed() -> void:
	if _inspector == null:
		return
	var written: int = _inspector.save_report("user://")
	_title_label.text = "AEGIS ECS INSPECTOR   saved %d files to user://" % written


func _dim(text: String) -> String:
	return "[color=%s]%s[/color]" % [COLOR_DIM, text]


func _value(text: String) -> String:
	return "[color=%s]%s[/color]" % [COLOR_TEXT, text]
