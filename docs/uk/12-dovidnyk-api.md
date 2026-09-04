[← Повний приклад](11-povnyi-pryklad.md) | [Зміст](README.md)

---

# 12. Довідник API

Повний перелік публічного API. Пояснення «чому саме так» — у відповідних
розділах, посилання додані.

---

## `EcsWorld`

Розподільник ідентифікаторів і реєстр сховищ. Див.
[розділ 3](03-svit-sutnosti-zhyttievyi-tsykl.md).

### Константи

| Константа | Значення |
|---|---|
| `INVALID_ENTITY` | `-1` |
| `INVALID_HANDLE` | `0` |

### Складання

| Метод | Опис |
|---|---|
| `_init(entity_capacity)` | Задати ємність і виділити всі буфери одразу |
| `register_store(store, type_id) -> bool` | Зареєструвати сховище **до** першої сутності |
| `get_store(type_id) -> EcsComponentStore` | Пошук за типом. Для складання й відлагодження, **не для гарячого циклу** |
| `has_store(type_id) -> bool` | |
| `get_store_count() -> int` | |
| `get_store_at(index) -> EcsComponentStore` | |
| `is_schema_locked() -> bool` | Чи вже створювалися сутності |

### Створення

| Метод | Опис |
|---|---|
| `create_entity() -> int` | Новий id, або **-1**, якщо світ повний |
| `create_entities(count, out_entities) -> int` | Пакетно; повертає скільки реально створено |
| `create_entity_handle() -> int` | Створити і одразу отримати handle |

### Handle

| Метод | Опис |
|---|---|
| `make_handle(entity) -> int` | Безпечне посилання, що переживає кадри |
| `entity_from_handle(handle) -> int` | Розв'язати, або `INVALID_ENTITY` |
| `is_handle_alive(handle) -> bool` | |
| `get_generation(entity) -> int` | |
| `get_world_tag() -> int` | |

### Знищення

| Метод | Опис |
|---|---|
| `queue_destroy(entity) -> bool` | Позначити. Ідемпотентно |
| `queue_destroy_many(entities, count) -> int` | Пакетно; повертає скільки додано в чергу |
| `queue_destroy_handle(handle) -> bool` | |
| `flush_destroy_queue() -> int` | **Structural sync point.** Рівно в одній точці кадру |
| `is_pending_destroy(entity) -> bool` | |
| `is_handle_pending_destroy(handle) -> bool` | |
| `is_alive(entity) -> bool` | З перевіркою меж |

### Ємність і скидання

| Метод | Опис |
|---|---|
| `reserve_capacity(n) -> bool` | Явний алокуючий бар'єр. `false`, якщо якесь сховище не підтримує зростання |
| `reset()` | Очистити світ **без алокацій**; інвалідує всі handle |
| `capacity` | Поточна ємність (тільки читання) |

### Діагностика

| Метод | Опис |
|---|---|
| `get_live_count()` / `get_free_count()` / `get_retired_count()` | |
| `get_pending_destroy_count()` | |
| `get_load_factor() -> float` | `live / capacity`, у `[0, 1]` |
| `structural_version` | Монотонний лічильник структурних змін |
| `validate_integrity(report_errors = true) -> bool` | Повна перевірка. **Не для продакшн-кадру** |
| `clear_change_logs()` | Очистити журнали всіх сховищ, де вони увімкнені |

---

## `EcsComponentStore`

Абстрактне sparse-set сховище. Див.
[розділ 4](04-komponenty-i-skhovyshcha.md).

### Публічні поля

| Поле | Опис |
|---|---|
| `type_id` | Ідентифікатор типу, під яким зареєстровано |
| `sparse_index` | `entity → слот`, або -1. **Тільки читання ззовні** |
| `dense_entities` | `слот → entity`. **Тільки читання ззовні** |
| `count` | Кількість компонентів = довжина щільного масиву |
| `structural_version` | Змінюється лише при зміні складу/розкладки |

### Журнал змін ([розділ 7.2](07-chas-podii-yemnist.md#72-журнал-змін--реакція-на-появу-і-смерть))

| Поле / метод | Опис |
|---|---|
| `track_changes: bool` | Увімкнути журнал. Типово `false` |
| `added_entities`, `added_count` | Дійсний префікс `[0, added_count)` |
| `removed_entities`, `removed_count` | Дійсний префікс `[0, removed_count)` |
| `change_log_overflowed` | `clear()`/`reset()` не логували поелементно |
| `clear_change_log()` | Очистити обидва журнали |

### Операції

| Метод | Опис |
|---|---|
| `attach(entity) -> int` | Приєднати; ідемпотентно; -1 при переповненні |
| `attach_many(entities, count) -> int` | Пакетно; нові слоти йдуть підряд від `count` **до** виклику |
| `detach(entity)` | Безпечно, навіть якщо компонента немає |
| `detach_many(entities, count) -> int` | Пакетно за списком жертв |
| `detach_flagged(flags) -> int` | Пакетно за байтовими прапорцями; мінімум перенесень |
| `has(entity) -> bool` | **Без перевірки меж** |
| `index_of(entity) -> int` | Слот або -1. **Без перевірки меж** |
| `entity_at(slot) -> int` | **Без перевірки меж** |
| `clear()` | Спорожнити без алокацій |
| `get_capacity() -> int` | |
| `is_initialized() -> bool` | |
| `supports_capacity_growth() -> bool` | Чи визначено `_grow_dense()` |
| `validate_integrity(alive, report) -> bool` | Перевірка бієкції sparse↔dense |

### Віртуальні методи

**Обов'язкові** (оголошені в базі):

| Метод | Опис |
|---|---|
| `_reserve_dense(capacity)` | Виділити свої payload-масиви |
| `_relocate_dense(from, to)` | Перенести дані при swap-remove |

**Необов'язкові** — визначаються автоматично через `has_method()`. Визначили —
працює; не визначили — не коштує нічого.

| Метод | Опис |
|---|---|
| `_grow_dense(prev, next)` | Вмикає `world.reserve_capacity()` |
| `_relocate_dense_batch(from, to, n)` | Пакетне перенесення |
| `_release_dense(slot)` | Звільнити володіння **перед** перезаписом |
| `_clear_relocated_dense(slot)` | Очистити дублікат у слоті-джерелі |
| `_clear_dense(active_count)` | Масове очищення при `clear()`/`reset()` |

---

## `EcsPackedStore`

Декларативне сховище. Реалізує `_reserve_dense`, `_grow_dense`,
`_relocate_dense` і `_relocate_dense_batch` узагальнено.

| Метод | Опис |
|---|---|
| `track(a, b, ...)` | Зареєструвати до 8 полів за іменами. Викликати в `_init()` |
| `track_field(name)` | Зареєструвати одне поле |
| `refresh_tracked_arrays()` | Якщо поле присвоїли **цілком** заново |
| `get_tracked_field_count() -> int` | |
| `get_tracked_field_name(i) -> StringName` | |
| `clear_slot(slot)` | Записати нуль відповідного типу в усі поля цього слота |

**Підтримувані типи полів:** будь-який `Packed*Array` і звичайний `Array`.

---

## `EcsTagStore`

Компонент-мітка без даних. Усе API успадковане; спеціалізовані `detach_many()`
і `detach_flagged()` взагалі не виконують перенесень.

---

## `EcsView`

Перетин сховищ без матеріалізації. Див. [розділ 6.2](06-poshuk-sutnostei.md#62-рівень-2-ecsview-без-алокацій).

| Метод | Опис |
|---|---|
| `configure(world, required, excluded = [], owner = null) -> bool` | Холодна операція, один раз |
| `refresh_driver()` | Обрати найменше з обов'язкових сховищ |
| `get_candidate_store() -> EcsComponentStore` | Ведуче сховище |
| `get_candidate_count() -> int` | |
| `get_driver_required_index() -> int` | Індекс ведучого серед обов'язкових |
| `matches(entity) -> bool` | Перевірка складу |
| `get_required_count()` / `get_required_store(i)` / `get_required_sparse(i)` | |
| `get_excluded_count()` / `get_excluded_store(i)` / `get_excluded_sparse(i)` | |
| `is_configured() -> bool` | |
| `validate_owner_access(report = true) -> bool` | Перевірка метаданих системи-власника |

---

## `EcsQuery`

Матеріалізований кеш поверх `EcsView`. Див.
[розділ 6.3](06-poshuk-sutnostei.md#63-рівень-3-ecsquery-кешований-результат).

| Метод | Опис |
|---|---|
| `configure(world, required, excluded = [], owner = null, maximum_results = -1) -> bool` | |
| `refresh() -> bool` | `true`, якщо кеш перебудовано |
| `is_current() -> bool` | Чи актуальний кеш |
| `count` | Розмір результату |
| `entity_at(i) -> int` | |
| `get_entities_unsafe() -> PackedInt32Array` | Швидкий буфер, **тільки читання** |
| `get_result_capacity() -> int` | |
| `is_truncated() -> bool` | Підходило більше, ніж вміщує ліміт |
| `get_rebuild_count() -> int` | Скільки разів перебудовувався |
| `get_view() -> EcsView` | |
| `validate_owner_access(report = true) -> bool` | |

---

## `EcsSystem`

Одиниця логіки. Див. [розділ 5](05-systemy-i-planuvalnyk.md).

| Поле | Опис |
|---|---|
| `system_name` | Задавати в `_init()`; потрапляє у профілювання |
| `system_phase` | Заморожується після `add_system()`; змінювати через планувальник |
| `enabled` | Runtime-вимикач |
| `requires_time` | `true` → планувальник пропускає систему при `delta <= 0` |
| `read_component_types` / `write_component_types` / `structural_write_component_types` | Метадані |
| `writes_world_structure` | `create`/`destroy`/`reset` |
| `access_metadata_complete` | |

| Метод | Опис |
|---|---|
| `setup(world, context)` | Один раз, коли все готове. Кешувати посилання тут |
| `execute(delta)` | Раз на кадр |
| `teardown()` | У зворотному порядку реєстрації |
| `declare_read(id)` / `declare_write(id)` / `declare_structural_write(id)` | Ланцюгові |
| `has_declared_access(id) -> bool` | |
| `complete_access_metadata()` | Підтвердити, що опис повний |

---

## `EcsScheduler`

| Метод | Опис |
|---|---|
| `add_system(system, phase = 0) -> EcsSystem` | Порядок реєстрації = порядок виконання |
| `setup_all(world, context) -> bool` | |
| `teardown_all()` | У зворотному порядку |
| `execute_all(delta)` | Весь конвеєр |
| `begin_frame()` | Закрити попередній кадр; обов'язково перед серією `execute_phase()` |
| `execute_phase(phase, delta)` | Одна фаза; заміри **накопичуються** до `begin_frame()` |
| `set_system_enabled(i, value)` / `is_system_enabled(i)` | |
| `set_phase_enabled(phase, value)` / `is_phase_enabled(phase)` | |
| `set_system_phase(i, phase)` | Безпечна зміна фази |
| `get_system_count()` / `get_system_name(i)` / `get_system(i)` / `get_system_phase(i)` | |
| `find_system(name) -> int` | Індекс або -1 |
| `was_system_executed(i) -> bool` | |
| `get_timing_usec(i) -> float` | Останній кадр |
| `get_average_timing_usec(i) -> float` | Згладжене; для HUD |
| `get_total_timing_usec() -> float` | |
| `reset_profiling()` | |
| `profiling_enabled` | Вимкнути заміри |
| `validate_pipeline(world, report = true) -> bool` | |
| `systems_conflict(a, b) -> bool` | Консервативний аналіз залежностей |

---

## `EcsReaperSystem`

Єдина точка знищення. Реєструвати **останньою**.

| Член | Опис |
|---|---|
| `_init(world = null, name = "Reaper")` | |
| `last_reaped` | Знищено цього кадру |
| `total_reaped` | Знищено всього |

Має `requires_time = false` навмисно: черга має розбиратися й на паузі.

---

## `EcsCapacityPolicySystem`

Автоматичне зростання світу. Реєструвати **одразу після жнеця**.

| Член | Опис |
|---|---|
| `_init(world = null, name = "CapacityPolicy")` | |
| `grow_threshold` | Частка заповнення для зростання. Типово `0.85` |
| `growth_factor` | Множник нової ємності. Типово `1.5` |
| `maximum_capacity` | Стеля; `0` = без обмеження |
| `check_interval_frames` | Типово `30` |
| `on_capacity_grown: Callable` | `call(previous, next)` після зростання |
| `grow_now() -> bool` | Примусово, ігноруючи інтервал |
| `growth_count`, `last_growth_capacity` | Діагностика |

---

## `SimulationClock`

Фіксований крок і масштаб часу. Див.
[розділ 7.1](07-chas-podii-yemnist.md#71-simulationclock--фіксований-крок-і-масштаб-часу).

| Член | Опис |
|---|---|
| `advance(real_delta) -> int` | Скільки суб-кроків виконати. **Рівно раз на кадр** |
| `fixed_step` | Довжина відрізка симуляції |
| `time_scale` | `0` = стоп, `1` = реальний час |
| `max_substeps` | Запобіжник від «спіралі смерті». Типово `8` |
| `paused` | Заморозити, не втрачаючи акумулятор |
| `get_last_substeps() -> int` | |
| `get_alpha() -> float` | Частка невитраченого відрізка, для інтерполяції |
| `is_saturated() -> bool` | Чи впирається в `max_substeps` |
| `get_effective_time_scale(real_delta) -> float` | Фактична швидкість |
| `elapsed_simulated` | Точна сума, без дрейфу |
| `total_substeps`, `dropped_substeps` | |
| `reset()` | |

---

## `UniformSpatialGrid`

Broadphase на counting sort. Див. [розділ 8](08-prostorovyi-poshuk.md).

| Константа | Значення |
|---|---|
| `MAX_QUERY_RESULTS` | `2048` |

| Метод | Опис |
|---|---|
| `configure(arena_radius, vertical_extent, cell_size, entry_capacity)` | `vertical_extent = 0` → плоский 2D-режим |
| `suggest_cell_size(arena_radius, vertical_extent, expected_entries, query_radius) -> float` | **Статичний.** Обґрунтована стартова точка |
| `rebuild(entity_ids, points, entry_count)` | Повна перебудова |
| `query_nearest(center, radius) -> int` | Найближчий id, або -1. Без алокацій |
| `query_sphere(center, radius, limit) -> int` | Кількість; id — у `query_buffer` |
| `get_cell_index(point) -> int` | |
| `get_cell_start(cell)` / `get_cell_end(cell)` | Межі комірки у відсортованих масивах |
| `get_entry_count()` / `get_cell_count()` / `get_cell_size()` | |
| `get_dimensions() -> Vector3i` | Комірок по осях; `y == 1` у плоскому режимі |
| `is_flat() -> bool` | |

| Поле | Опис |
|---|---|
| `query_buffer` | Результат останнього `query_sphere`. **Перезаписується наступним запитом** |
| `query_point_buffer` | Позиції; заповнюється лише при `store_query_points = true` |
| `store_query_points` | Типово `false` |
| `sorted_entities`, `sorted_points` | Відсортовані за комірками. **Тільки читання** |

---

## `AngleMath`

| Метод | Опис |
|---|---|
| `approach(current, desired, max_step) -> float` | **Статичний.** Доворот найкоротшим шляхом |
| `shortest_delta(from, to) -> float` | **Статичний.** Абсолютна кутова відстань |

---

## Відладкова частина

Повністю описана в [розділі 13](13-inspektor.md). Тека `debug/` не містить нод і
безпечна в релізі; `inspector/` містить панель і вирізається з експорту.

### `EcsInspector`

Єдина точка підключення.

| Член | Опис |
|---|---|
| `attach(scheduler, world, options) -> EcsInspector` | **Статичний.** Ніколи не повертає `null` |
| `capture()` | **Останнім рядком кадру.** Заміряє й настінний час |
| `refresh_now()` | Негайно перерахувати агрегати й діагностику |
| `add_counter_section(title, provider: Callable)` | Лічильники застосунку |
| `register_query(name, query)` / `register_grid(name, grid)` / `set_clock(clock)` | Об'єкти для діагностики |
| `get_findings() -> Array` | Знахідки, найгірші першими |
| `has_panel()` / `get_panel()` / `set_panel_visible(v)` | Інтерфейс, якщо він є |
| `print_report()` / `print_worst_frame()` / `save_report(dir)` | Звіти |
| `detach()` | Прибрати панель і зупинити збір |
| `mode` | `OFF` / `TELEMETRY` / `INSPECTOR` / `DEV` |
| `stats_refresh_hz`, `diagnostics_refresh_hz` | Частоти перерахунку |
| `recorder`, `stats`, `diagnostics` | Прямий доступ до складових |

Ключі `options`: `mode`, `parent`, `frames`, `clock`, `grids`, `queries`,
`budget_usec`.

### `EcsFrameRecorder`

Кільцевий буфер кадрів. Після `configure()` не алокує.

| Член | Опис |
|---|---|
| `configure(scheduler, world, frames = 240) -> bool` | |
| `capture(substeps = 1, wall_frame_usec = 0.0)` | |
| `clear()` | Забути вікно без переалокації |
| `get_frame_count()` / `get_frames_seen()` | |
| `get_newest_slot()` / `get_oldest_slot()` / `get_slot_in_order(i)` / `get_slot_from_newest(age)` | |
| `get_frame_total_usec(slot)` / `get_frame_wall_usec(slot)` / `get_frame_substeps(slot)` | |
| `get_frame_live_count(slot)` / `get_frame_pending_destroy(slot)` / `get_frame_structural_delta(slot)` | |
| `get_timing_usec(slot, system)` / `get_status(slot, system)` | |
| `get_timings_unsafe()` / `get_status_unsafe()` | Пласкі буфери, тільки читання |
| `last_capture_usec` / `get_memory_usage()` | Вартість спостереження |
| `Status` | `EXECUTED` / `SKIPPED_PAUSED` / `DISABLED` / `PHASE_OFF` |

### `EcsFrameStats`

| Член | Опис |
|---|---|
| `analyse(recorder) -> bool` | Холодний шлях: сортує вікно |
| `get_frame_median_usec()` / `get_frame_p95_usec()` / `get_frame_max_usec()` / `get_frame_average_usec()` | |
| `get_worst_frame_slot()` | Слот найгіршого кадру — для повного розбору |
| `get_spike_frame_count()` / `get_spike_ratio()` | Чи є ривки |
| `get_system_median_usec(i)` / `get_system_p95_usec(i)` / `get_system_max_usec(i)` | |
| `get_system_share_percent(i)` | Частка часу ECS |
| `get_system_volatility(i)` | `max / median` — хто дає ривки |
| `get_system_excess_share(i)` | Частка надлишку в повільних кадрах |
| `get_spike_contributor(rank)` | Ранжування винуватців |
| `get_live_min()` / `get_live_max()` / `get_capacity_change_count()` / `get_peak_pending_destroy()` | |
| `spike_factor`, `high_percentile` | Налаштування |

### `EcsDiagnostics`

| Член | Опис |
|---|---|
| `inspect(recorder, stats, world, extras = {}) -> Array` | Знахідки, найгірші першими |
| `reset()` | Забути лічильники перебудов запитів |
| `frame_budget_usec`, `volatility_warning`, `load_factor_warning`, `store_fill_warning`, `spike_ratio_warning`, `dominant_share_percent`, `excess_share_warning` | Пороги |
| `EcsDiagnostics.Finding` | `severity`, `source`, `title`, `detail`, `hint`, `format()` |

### `EcsReport`

Усі методи статичні.

| Метод | Опис |
|---|---|
| `to_text(recorder, stats, world, findings) -> String` | Звіт для тікета |
| `frame_to_text(recorder, slot, stats) -> String` | Розбір одного кадру |
| `to_dictionary(...) -> Dictionary` | Для JSON |
| `to_csv(recorder) -> String` | Рядок на кадр, стовпець на систему |
| `save_text(path, ...)` / `save_json(path, ...)` / `save_csv(path, ...)` | |

---

[← Повний приклад](11-povnyi-pryklad.md) | [Зміст](README.md) | [Інспектор →](13-inspektor.md)
