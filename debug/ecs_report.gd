class_name EcsReport
extends RefCounted

## Отрисовывает записанное окно как текст или JSON.
##
## Текстовая форма предназначена для вставки в тикет: это вся история прогона
## примерно в тридцати строках. Форма JSON — чтобы приложить к тикету файлом или
## сравнивать между сборками в CI.
##
## Всё здесь статическое и без побочных эффектов, поэтому работает headless, без
## интерфейса и без дерева сцены.
##
## [codeblock]
## print(EcsReport.to_text(recorder, stats, world))
## EcsReport.save_json("user://ecs_report.json", recorder, stats, world)
## [/codeblock]

## Полный текстовый отчёт: распределение, таблица по системам, атрибуция
## всплесков.
static func to_text(recorder: EcsFrameRecorder, stats: EcsFrameStats, world: EcsWorld = null,
		findings: Array = []) -> String:
	if recorder == null or stats == null or not stats.is_analysed():
		return "EcsReport: пока ничего не записано."

	var lines: PackedStringArray = PackedStringArray()
	lines.append("=== Aegis ECS report ===")
	lines.append("window %d frames (%d seen), %d systems"
		% [stats.get_frame_count(), recorder.get_frames_seen(), stats.get_system_count()])

	lines.append("")
	lines.append("-- frame cost --")
	lines.append("  median %8.3f ms   <- the typical frame" % (stats.get_frame_median_usec() / 1000.0))
	lines.append("  p95    %8.3f ms   <- what most frames stay under" % (stats.get_frame_p95_usec() / 1000.0))
	lines.append("  max    %8.3f ms   (%.1fx the median)"
		% [stats.get_frame_max_usec() / 1000.0, stats.get_spike_ratio()])
	lines.append("  mean   %8.3f ms" % (stats.get_frame_average_usec() / 1000.0))
	lines.append("  slow frames: %d of %d (%.1f%%)"
		% [stats.get_spike_frame_count(), stats.get_frame_count(), stats.get_spike_frame_percent()])

	if world != null:
		lines.append("")
		lines.append("-- world --")
		lines.append("  entities %d / %d (%.0f%%), live range over window %d..%d"
			% [world.get_live_count(), world.capacity, world.get_load_factor() * 100.0,
			   stats.get_live_min(), stats.get_live_max()])
		lines.append("  stores %d, capacity changes %d, peak pending destroy %d"
			% [world.get_store_count(), stats.get_capacity_change_count(),
			   stats.get_peak_pending_destroy()])

	lines.append("")
	lines.append("-- systems, microseconds --")
	lines.append("  %-26s %8s %8s %8s %8s %7s" % ["system", "median", "p95", "max", "share%", "volat."])
	for index in stats.get_system_count():
		lines.append("  %-26s %8d %8d %8d %7.1f%% %6.1fx" % [
			recorder.get_system_name(index),
			int(stats.get_system_median_usec(index)),
			int(stats.get_system_p95_usec(index)),
			int(stats.get_system_max_usec(index)),
			stats.get_system_share_percent(index),
			stats.get_system_volatility(index),
		])

	lines.append("")
	lines.append("-- what makes the slow frames slow --")
	lines.append("  (excess over each system's own median, across the slowest %d frames)"
		% stats.get_attributed_frame_count())
	var listed: int = 0
	for rank in stats.get_spike_contributor_count():
		var index: int = stats.get_spike_contributor(rank)
		if stats.get_system_excess_usec(index) <= 0.0 or listed >= 5:
			break
		lines.append("  %d. %-24s %5.1f%% of the excess   median %d us, peak %d us (%.0fx)" % [
			rank + 1, recorder.get_system_name(index),
			stats.get_system_excess_share(index),
			int(stats.get_system_median_usec(index)),
			int(stats.get_system_max_usec(index)),
			stats.get_system_volatility(index),
		])
		listed += 1
	if listed == 0:
		lines.append("  nothing stands out - the slow frames are slow evenly.")

	if not findings.is_empty():
		lines.append("")
		lines.append("-- diagnostics --")
		for finding in findings:
			lines.append("  " + finding.format().replace("\n", "\n  "))

	lines.append("")
	lines.append("-- observer cost --")
	lines.append("  capture %.2f us/frame, window memory %.1f KB"
		% [recorder.last_capture_usec, recorder.get_memory_usage() / 1024.0])
	return "\n".join(lines)


## Разбор одного записанного кадра, в порядке вызова систем. Передайте
## [method EcsFrameStats.get_worst_frame_slot], чтобы препарировать худший.
static func frame_to_text(recorder: EcsFrameRecorder, slot: int, stats: EcsFrameStats = null) -> String:
	if recorder == null or slot < 0:
		return "EcsReport: такого кадра нет."
	var lines: PackedStringArray = PackedStringArray()
	var total: float = recorder.get_frame_total_usec(slot)
	var substeps: int = recorder.get_frame_substeps(slot)
	lines.append("=== frame #%d: %.3f ms, %d entities, %d substep(s) ==="
		% [recorder.get_frame_id(slot), total / 1000.0, recorder.get_frame_live_count(slot), substeps])

	lines.append("  %-26s %8s %8s  %s" % ["system", "us", "share", ""])
	for index in recorder.system_count:
		var value: float = recorder.get_timing_usec(slot, index)
		var share: float = (value / total * 100.0) if total > 0.0 else 0.0
		var marker: String = ""
		if stats != null and stats.is_analysed():
			var median: float = stats.get_system_median_usec(index)
			if value > median * 2.0 and value - median > 20.0:
				marker = "  <-- %.0fx its median (%d us)" % [value / maxf(median, 1.0), int(median)]
		var status: int = recorder.get_status(slot, index)
		var suffix: String = ""
		match status:
			EcsFrameRecorder.Status.SKIPPED_PAUSED:
				suffix = "  (paused)"
			EcsFrameRecorder.Status.DISABLED:
				suffix = "  (disabled)"
			EcsFrameRecorder.Status.PHASE_OFF:
				suffix = "  (phase off)"
		lines.append("  %-26s %8d %7.1f%%  %s%s%s" % [
			recorder.get_system_name(index), int(value), share,
			"#".repeat(int(share / 4.0)), marker, suffix,
		])
	return "\n".join(lines)


## Машиночитаемый снимок окна.
static func to_dictionary(recorder: EcsFrameRecorder, stats: EcsFrameStats,
		world: EcsWorld = null, findings: Array = []) -> Dictionary:
	var result: Dictionary = {
		"version": 1,
		"frames_in_window": stats.get_frame_count() if stats != null else 0,
		"frames_seen": recorder.get_frames_seen() if recorder != null else 0,
	}
	if stats != null and stats.is_analysed():
		result["frame"] = {
			"median_usec": stats.get_frame_median_usec(),
			"p95_usec": stats.get_frame_p95_usec(),
			"max_usec": stats.get_frame_max_usec(),
			"mean_usec": stats.get_frame_average_usec(),
			"spike_frames": stats.get_spike_frame_count(),
			"spike_ratio": stats.get_spike_ratio(),
		}
		var systems: Array = []
		for index in stats.get_system_count():
			systems.append({
				"name": recorder.get_system_name(index),
				"phase": recorder.get_system_phase(index),
				"median_usec": stats.get_system_median_usec(index),
				"p95_usec": stats.get_system_p95_usec(index),
				"max_usec": stats.get_system_max_usec(index),
				"share_percent": stats.get_system_share_percent(index),
				"volatility": stats.get_system_volatility(index),
				"excess_share_percent": stats.get_system_excess_share(index),
				"executed_frames": stats.get_system_executed_frames(index),
			})
		result["systems"] = systems
	if world != null:
		result["world"] = {
			"live": world.get_live_count(),
			"capacity": world.capacity,
			"load_factor": world.get_load_factor(),
			"stores": world.get_store_count(),
			"pending_destroy": world.get_pending_destroy_count(),
		}
	if not findings.is_empty():
		var issues: Array = []
		for finding in findings:
			issues.append({
				"severity": finding.severity_label(),
				"source": finding.source,
				"title": finding.title,
				"detail": finding.detail,
				"hint": finding.hint,
			})
		result["diagnostics"] = issues
	return result


## Покадровый CSV всего окна: строка на кадр, столбец на систему. Подходит для
## таблицы или скрипта построения графиков.
static func to_csv(recorder: EcsFrameRecorder) -> String:
	if recorder == null or recorder.get_frame_count() == 0:
		return ""
	var header: PackedStringArray = PackedStringArray(["frame", "total_usec", "live", "substeps"])
	for index in recorder.system_count:
		header.append(recorder.get_system_name(index).replace(",", "_"))
	var lines: PackedStringArray = PackedStringArray([",".join(header)])

	for order in recorder.get_frame_count():
		var slot: int = recorder.get_slot_in_order(order)
		var row: PackedStringArray = PackedStringArray([
			str(recorder.get_frame_id(slot)),
			"%.1f" % recorder.get_frame_total_usec(slot),
			str(recorder.get_frame_live_count(slot)),
			str(recorder.get_frame_substeps(slot)),
		])
		for index in recorder.system_count:
			row.append("%.1f" % recorder.get_timing_usec(slot, index))
		lines.append(",".join(row))
	return "\n".join(lines)


static func save_json(path: String, recorder: EcsFrameRecorder, stats: EcsFrameStats,
		world: EcsWorld = null, findings: Array = []) -> bool:
	return _write(path, JSON.stringify(to_dictionary(recorder, stats, world, findings), "  "))


static func save_csv(path: String, recorder: EcsFrameRecorder) -> bool:
	return _write(path, to_csv(recorder))


static func save_text(path: String, recorder: EcsFrameRecorder, stats: EcsFrameStats,
		world: EcsWorld = null, findings: Array = []) -> bool:
	return _write(path, to_text(recorder, stats, world, findings))


static func _write(path: String, content: String) -> bool:
	var file: FileAccess = FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		push_error("EcsReport: не удалось записать «%s» (%s)" % [path, error_string(FileAccess.get_open_error())])
		return false
	file.store_string(content)
	file.close()
	return true
