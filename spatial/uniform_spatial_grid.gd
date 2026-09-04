class_name UniformSpatialGrid
extends RefCounted

## Равномерная 3D-сетка широкой фазы (broadphase) на основе counting sort
## поверх Packed-массивов.
##
## «Broadphase» отвечает на вопрос «какие объекты находятся рядом с точкой X»,
## не перебирая все объекты (полный перебор — это O(n) на запрос и O(n²)
## суммарно, если запросов тоже n; недопустимо уже на паре тысяч объектов, а тем
## более на десятках тысяч). Пространство режется на равные ячейки: объект
## попадает в ячейку по своим координатам, и «кто рядом» сводится к просмотру
## нескольких соседних ячеек вместо всего мира.
##
## Сетка рассчитана на сценарий «всё движется каждый кадр»: точечного
## перемещения объекта нет, индекс целиком перестраивается вызовом
## [method rebuild]. Когда сдвинулось почти всё, это дешевле n отдельных
## обновлений.
##
## [b]ПОЧЕМУ COUNTING SORT, А НЕ Dictionary «ячейка -> список»[/b]: словарь в
## GDScript — это хеш-таблица общего назначения с накладными расходами на каждую
## вставку и, что хуже, с аллокациями при росте. Перестраивать такое каждый кадр
## в бюджет не укладывается. Counting sort вместо этого перекладывает все записи
## за ТРИ линейных прохода вообще без аллокаций (все буферы преаллоцированы в
## [method configure]), причём все три работают с ОДНИМ И ТЕМ ЖЕ массивом
## `_cell_offsets` — отдельного массива-курсора нет:
##   Проход 1: вычислить ячейку каждой записи и увеличить её счётчик (гистограмма).
##   Проход 2: превратить гистограмму во ВКЛЮЧАЮЩИЕ префиксные суммы на месте,
##             так что _cell_offsets[c] становится индексом СРАЗУ ЗА последней
##             записью ячейки c.
##   Проход 3: разложить записи по итоговым слотам, идя ОТ КОНЦА К НАЧАЛУ и
##             уменьшая _cell_offsets[cell] перед каждой записью. Побочный
##             эффект — ровно то, что нужно дальше: к концу прохода каждый
##             _cell_offsets[c] уменьшен ровно на размер своей ячейки и снова
##             указывает на её НАЧАЛО.
## Результат — массив, отсортированный по ячейкам: всё, что в одной ячейке,
## лежит подряд, и ни одного malloc за всю перестройку.
##
## ПОЧЕМУ В ПРОХОДЕ 3 ИДЁМ НАЗАД: это классический приём counting sort, который
## позволяет одному массиву делать работу двух (гистограмма плюс курсор записи).
## Экономия не только в памяти (40 КБ на сетке в 10 000 ячеек), но и в скорости:
## горячий цикл трогает один массив вместо двух, то есть вдвое меньше кэш-линий.
## При этом сортировка остаётся УСТОЙЧИВОЙ.
##
## [b]ЦЕНА ПЕРЕСТРОЙКИ — O(записи + ЯЧЕЙКИ)[/b], а не только O(записи): проходы
## 1 и 3 линейны по числу записей, но проход 2 обязан пройти по КАЖДОЙ ячейке,
## включая пустые. Именно поэтому [param cell_size] так важен: сетка из 10 000
## ячеек, в которой живёт 30 объектов, тратит почти всё время на пустоту.
## Держите [method get_cell_count] соразмерным ожидаемому числу объектов или
## вызовите [method suggest_cell_size] и пусть арифметику сделает он.
##
## [b]ПЛОСКИЙ (2D) РЕЖИМ[/b]: передайте `vertical_extent = 0.0`, и сетка
## схлопнется в один слой, сократив число ячеек — а вместе с ним и постоянную
## часть каждой перестройки — во столько раз, сколько вертикальных слоёв было бы
## иначе. Для игры сверху вниз, RTS, bullet hell или чего угодно на плоскости
## это бесплатная скорость; см. [method configure].
##
## РАСКЛАДКА ИНДЕКСОВ ЯЧЕЕК подобрана так, чтобы весь X-диапазон одной строки был
## НЕПРЕРЫВЕН в отсортированном массиве (cell = (cy*dim_z + cz)*dim_x + cx).
## Поэтому запрос по сфере читает одну плоскую полосу на строку, а не дёргает
## каждую ячейку отдельно — меньше промахов кэша и меньше обращений к массиву.

## Верхняя граница на то, сколько id может вернуть один вызов query_sphere().
const MAX_QUERY_RESULTS: int = 2048

var _cell_size: float = 1.0
var _inv_cell_size: float = 1.0
var _dim_x: int = 0
var _dim_y: int = 0
var _dim_z: int = 0
var _cell_count: int = 0
var _origin_xz: float = 0.0
var _flat: bool = false

## Размер — _cell_count + 1. По ходу [method rebuild] массив последовательно
## играет три роли: гистограмма -> «концы» ячеек -> «начала» ячеек. К моменту
## возврата из rebuild это всегда «начала»: _cell_offsets[c] — индекс первой
## записи ячейки c, а _cell_offsets[c + 1] — индекс сразу за её последней.
var _cell_offsets: PackedInt32Array = PackedInt32Array()

var _scratch_cells: PackedInt32Array = PackedInt32Array()
var _entry_count: int = 0

## Записи, отсортированные по ячейкам. Снаружи только для чтения — так же, как
## публичные поля [EcsComponentStore]: открыты, чтобы система могла написать
## собственный обход (все пары внутри ячейки, нестандартная форма, k ближайших)
## без лишнего копирования. Действительный префикс — [0, get_entry_count()).
var sorted_entities: PackedInt32Array = PackedInt32Array()
var sorted_points: PackedVector3Array = PackedVector3Array()

## Результат последнего [method query_sphere]. Снаружи только для чтения и
## ПЕРЕЗАПИСЫВАЕТСЯ следующим запросом.
var query_buffer: PackedInt32Array = PackedInt32Array()

## Позиции, соответствующие [member query_buffer]; заполняются, только пока
## [member store_query_points] равно true.
var query_point_buffer: PackedVector3Array = PackedVector3Array()

## Заставляет [method query_sphere] заполнять ещё и [member query_point_buffer].
## По умолчанию выключено, чтобы те, кому нужны только id, не платили за лишнюю
## запись; включённое — экономит вызывающему коду поиск через sparse плюс чтение
## массива на каждое попадание, а это типичная форма цикла стайного поведения
## или расталкивания.
var store_query_points: bool = false


## [param arena_radius] задаёт границу по плоскости XZ (арена — квадрат или круг
## вокруг начала координат), [param vertical_extent] — границу по Y вверх от
## нуля. Всё, что выходит за эти границы, не теряется и не вызывает ошибку — оно
## зажимается в краевые ячейки, поэтому запросы у границы арены остаются
## корректными.
##
## [b]Для плоского мира передайте `vertical_extent = 0.0`[/b], и сетка будет
## использовать один слой по Y. Координата Y тогда игнорируется при раскладке по
## ячейкам (проверки расстояния по-прежнему полностью трёхмерные) — это ровно то
## что нужно игре на плоскости, и это убирает вертикальный множитель из числа
## ячеек.
##
## [param entry_capacity] — наибольшее число записей, которое когда-либо получит
## один [method rebuild]; буферы рассчитываются под него один раз здесь.
func configure(arena_radius: float, vertical_extent: float, cell_size: float, entry_capacity: int) -> void:
	_cell_size = maxf(cell_size, 0.01)
	_inv_cell_size = 1.0 / _cell_size
	_origin_xz = -arena_radius
	_dim_x = int(ceil(arena_radius * 2.0 * _inv_cell_size)) + 1
	_dim_z = _dim_x
	_flat = vertical_extent <= 0.0
	_dim_y = 1 if _flat else int(ceil(maxf(vertical_extent, _cell_size) * _inv_cell_size)) + 1
	_cell_count = _dim_x * _dim_y * _dim_z

	_cell_offsets.resize(_cell_count + 1)
	_scratch_cells.resize(entry_capacity)
	sorted_entities.resize(entry_capacity)
	sorted_points.resize(entry_capacity)
	query_buffer.resize(mini(entry_capacity, MAX_QUERY_RESULTS))
	query_point_buffer.resize(query_buffer.size())
	_entry_count = 0


## Предлагает [param cell_size] для [method configure].
##
## Две силы тянут в разные стороны: мелкие ячейки делают перестройку дорогой
## (проход 2 идёт по всем ячейкам), но запросы дешёвыми; крупные делают
## перестройку почти бесплатной, но запросы дорогими (больше далёких кандидатов
## приходится проверять по расстоянию). Точка равновесия — примерно «одна ячейка
## на ожидаемый объект», с нижней границей около двойного типичного радиуса
## запроса, чтобы запрос всё ещё читал лишь несколько ячеек.
##
## Для плоской сетки передайте `vertical_extent = 0.0`, как и в
## [method configure]. Результат — отправная точка, а не закон: профилируйте и
## корректируйте.
static func suggest_cell_size(
	arena_radius: float,
	vertical_extent: float,
	expected_entries: int,
	typical_query_radius: float,
) -> float:
	var span: float = maxf(arena_radius * 2.0, 0.01)
	var entries: float = float(maxi(expected_entries, 1))
	var density_size: float
	if vertical_extent <= 0.0:
		# (span / c)^2 == записи
		density_size = span / sqrt(entries)
	else:
		# (span / c)^2 * (vertical_extent / c) == записи
		density_size = pow(span * span * maxf(vertical_extent, 0.01) / entries, 1.0 / 3.0)
	return maxf(density_size, maxf(typical_query_radius, 0.01) * 2.0)


## Полностью перестраивает индекс из плоской пары массивов «id сущности,
## точка». Оба обязаны содержать не менее [param entry_count] действительных
## элементов — это позволяет вызывающей системе держать переиспользуемые буферы
## с запасом и передавать только заполненную часть, ничего не обрезая.
func rebuild(entity_ids: PackedInt32Array, points: PackedVector3Array, entry_count: int) -> void:
	# Защита от переполнения преаллоцированных буферов: сетка физически не может
	# принять больше записей, чем было заявлено в configure(). Молча взять первые
	# entry_capacity лучше, чем выйти за границу массива.
	entry_count = clampi(entry_count, 0, _scratch_cells.size())
	_entry_count = entry_count
	_cell_offsets.fill(0)
	if entry_count <= 0:
		# Все смещения нулевые, поэтому любая полоса [start, end) пуста, и запросы
		# корректно ничего не находят даже без раннего выхода.
		return

	var last_x: int = _dim_x - 1
	var last_z: int = _dim_z - 1
	var cells: PackedInt32Array = _scratch_cells
	var offsets: PackedInt32Array = _cell_offsets
	var origin: float = _origin_xz
	var inv: float = _inv_cell_size
	var dim_x: int = _dim_x
	var dim_z: int = _dim_z

	# Проход 1 — определить ячейку каждой записи и построить гистограмму в _cell_offsets.
	if _flat:
		for i in entry_count:
			var p: Vector3 = points[i]
			var cx: int = clampi(int((p.x - origin) * inv), 0, last_x)
			var cz: int = clampi(int((p.z - origin) * inv), 0, last_z)
			var cell: int = cz * dim_x + cx
			cells[i] = cell
			offsets[cell] += 1
	else:
		var last_y: int = _dim_y - 1
		for i in entry_count:
			var p: Vector3 = points[i]
			var cx: int = clampi(int((p.x - origin) * inv), 0, last_x)
			var cy: int = clampi(int(p.y * inv), 0, last_y)
			var cz: int = clampi(int((p.z - origin) * inv), 0, last_z)
			var cell: int = (cy * dim_z + cz) * dim_x + cx
			cells[i] = cell
			offsets[cell] += 1

	# Проход 2 — превратить гистограмму во ВКЛЮЧАЮЩИЕ префиксные суммы на месте,
	# так что _cell_offsets[c] — индекс сразу за последней записью ячейки c.
	# Последний элемент (индекс _cell_count) — общее число записей: он служит
	# «концом» последней ячейки и в проходе 3 не меняется, так как ни одна запись
	# эту ячейку не адресует.
	var running: int = 0
	for c in _cell_count:
		running += offsets[c]
		offsets[c] = running
	offsets[_cell_count] = running

	# Проход 3 — раскладываем записи, идя ОТ КОНЦА К НАЧАЛУ и уменьшая «конец»
	# каждой ячейки перед каждой записью. После прохода каждый _cell_offsets[c]
	# уменьшен ровно на размер своей ячейки, то есть снова указывает на её начало —
	# отдельный массив-курсор не нужен.
	var out_entities: PackedInt32Array = sorted_entities
	var out_points: PackedVector3Array = sorted_points
	var i: int = entry_count
	while i > 0:
		i -= 1
		var cell: int = cells[i]
		var slot: int = offsets[cell] - 1
		offsets[cell] = slot
		out_entities[slot] = entity_ids[i]
		out_points[slot] = points[i]


## Возвращает id ближайшей проиндексированной сущности в радиусе
## [param radius], либо -1. Ничего не аллоцирует — именно это делает безопасным
## широкий радиус поиска: его расширение стоит процессорного времени, но никогда
## не памяти.
##
## Как и query_sphere ниже, сначала вычисляет ограничивающий ячейками
## параллелепипед вокруг сферы и обходит только ячейки внутри него, а не всю
## сетку.
func query_nearest(center: Vector3, radius: float) -> int:
	if _entry_count <= 0:
		return -1
	var best_entity: int = -1
	var best_distance_sq: float = radius * radius

	var min_x: int = clampi(int((center.x - radius - _origin_xz) * _inv_cell_size), 0, _dim_x - 1)
	var max_x: int = clampi(int((center.x + radius - _origin_xz) * _inv_cell_size), 0, _dim_x - 1)
	var min_y: int = clampi(int((center.y - radius) * _inv_cell_size), 0, _dim_y - 1)
	var max_y: int = clampi(int((center.y + radius) * _inv_cell_size), 0, _dim_y - 1)
	var min_z: int = clampi(int((center.z - radius - _origin_xz) * _inv_cell_size), 0, _dim_z - 1)
	var max_z: int = clampi(int((center.z + radius - _origin_xz) * _inv_cell_size), 0, _dim_z - 1)

	var offsets: PackedInt32Array = _cell_offsets
	var points: PackedVector3Array = sorted_points
	var entities: PackedInt32Array = sorted_entities

	for cy in range(min_y, max_y + 1):
		for cz in range(min_z, max_z + 1):
			# Благодаря раскладке (cy*dim_z + cz)*dim_x + cx весь X-диапазон одной строки
			# лежит подряд, поэтому здесь читается одна плоская полоса [start, end), а не
			# dim_x отдельных ячеек.
			var row_base: int = (cy * _dim_z + cz) * _dim_x
			var slice_start: int = offsets[row_base + min_x]
			var slice_end: int = offsets[row_base + max_x + 1]
			for s in range(slice_start, slice_end):
				var distance_sq: float = points[s].distance_squared_to(center)
				if distance_sq < best_distance_sq:
					best_distance_sq = distance_sq
					best_entity = entities[s]
	return best_entity


## Заполняет [member query_buffer] всеми проиндексированными сущностями в
## радиусе [param radius] и возвращает, сколько id записано (не больше
## [param result_limit] и не больше собственного размера буфера).
##
## [b]Результат намеренно попадает в поле, а не в выходной параметр.[/b] Тогда
## владение и время жизни результата очевидны, а возврат нового массива
## аллоцировал бы на каждый запрос. Внутренний буфер переиспользуется, поэтому
## установившийся запрос не аллоцирует ничего.
##
## Выставьте [member store_query_points], чтобы получить ещё и соответствующие
## позиции в [member query_point_buffer].
##
## [b]Внимание:[/b] оба буфера перезаписываются следующим запросом. Читайте их
## до следующего запроса либо копируйте нужное.
##
## При достижении лимита просмотр прекращается, поэтому обрезанный результат
## смещён к нижнему углу области поиска, а не является случайной выборкой.
func query_sphere(center: Vector3, radius: float, result_limit: int) -> int:
	if _entry_count <= 0:
		return 0
	var capped_limit: int = mini(result_limit, query_buffer.size())
	if capped_limit <= 0:
		return 0
	var written: int = 0
	var radius_sq: float = radius * radius

	var min_x: int = clampi(int((center.x - radius - _origin_xz) * _inv_cell_size), 0, _dim_x - 1)
	var max_x: int = clampi(int((center.x + radius - _origin_xz) * _inv_cell_size), 0, _dim_x - 1)
	var min_y: int = clampi(int((center.y - radius) * _inv_cell_size), 0, _dim_y - 1)
	var max_y: int = clampi(int((center.y + radius) * _inv_cell_size), 0, _dim_y - 1)
	var min_z: int = clampi(int((center.z - radius - _origin_xz) * _inv_cell_size), 0, _dim_z - 1)
	var max_z: int = clampi(int((center.z + radius - _origin_xz) * _inv_cell_size), 0, _dim_z - 1)

	var offsets: PackedInt32Array = _cell_offsets
	var points: PackedVector3Array = sorted_points
	var entities: PackedInt32Array = sorted_entities
	var out_ids: PackedInt32Array = query_buffer
	var out_points: PackedVector3Array = query_point_buffer
	var with_points: bool = store_query_points

	for cy in range(min_y, max_y + 1):
		for cz in range(min_z, max_z + 1):
			var row_base: int = (cy * _dim_z + cz) * _dim_x
			var slice_start: int = offsets[row_base + min_x]
			var slice_end: int = offsets[row_base + max_x + 1]
			for s in range(slice_start, slice_end):
				# Диапазон ячеек — это лишь ограничивающий параллелепипед сферы, а не сама
				# сфера, поэтому каждая точка полосы всё равно проверяется точным расстоянием:
				# иначе в результат попали бы угловые точки дальше radius.
				var point: Vector3 = points[s]
				if point.distance_squared_to(center) > radius_sq:
					continue
				if written >= capped_limit:
					return written
				out_ids[written] = entities[s]
				if with_points:
					out_points[written] = point
				written += 1
	return written


## Индекс ячейки, содержащей [param point], либо -1, если сетка не настроена.
## В связке с [method get_cell_start] / [method get_cell_end] позволяет написать
## собственный обход по [member sorted_entities] и [member sorted_points].
func get_cell_index(point: Vector3) -> int:
	if _cell_count <= 0:
		return -1
	var cx: int = clampi(int((point.x - _origin_xz) * _inv_cell_size), 0, _dim_x - 1)
	var cz: int = clampi(int((point.z - _origin_xz) * _inv_cell_size), 0, _dim_z - 1)
	if _flat:
		return cz * _dim_x + cx
	var cy: int = clampi(int(point.y * _inv_cell_size), 0, _dim_y - 1)
	return (cy * _dim_z + cz) * _dim_x + cx


## Первый индекс ячейки [param cell] в отсортированных массивах.
func get_cell_start(cell: int) -> int:
	return _cell_offsets[cell]


## Индекс сразу за последним элементом ячейки [param cell].
func get_cell_end(cell: int) -> int:
	return _cell_offsets[cell + 1]


func get_entry_count() -> int:
	return _entry_count


func get_cell_count() -> int:
	return _cell_count


func get_cell_size() -> float:
	return _cell_size


## Число ячеек по осям, как (x, y, z). В плоском режиме y равен 1.
func get_dimensions() -> Vector3i:
	return Vector3i(_dim_x, _dim_y, _dim_z)


func is_flat() -> bool:
	return _flat
