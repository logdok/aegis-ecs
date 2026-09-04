[← Типові помилки](10-typovi-pomylky.md) | [Зміст](README.md) | [Довідник API →](12-dovidnyk-api.md)

---

# 11. Повний приклад: колонія в чашці Петрі

Цей розділ розбирає **робочий** приклад, який лежить у репозиторії:

```bash
godot --headless --script res://addons/aegis_ecs/example/colony_example.gd
```

Клітини блукають, витрачають енергію, розштовхуються, діляться, коли ситі, і
гинуть, коли голодні. Приклад навмисно зібраний так, щоб задіяти **все**, що
потрібно справжній симуляції:

| Що використано | Навіщо тут |
|---|---|
| `EcsPackedStore` | payload без шаблонного коду |
| `EcsTagStore` | ознака «готова ділитися» без даних |
| `UniformSpatialGrid` | «хто поруч», у плоскому 2D-режимі |
| `SimulationClock` | прискорення часу без розсинхрону |
| журнал змін | реакція на народження й смерть |
| `EcsCapacityPolicySystem` | населення може подвоїтися за секунди |
| `EcsReaperSystem` | єдина точка знищення |
| фази | суб-кроки симуляції проти роботи раз на кадр |

Типовий вивід:

```
grid: cell_size=6.00, cells=441, flat=true
seeded 200 cells

frame  population  births  deaths  capacity
    0         200     200       0       512
   60         584     584       0      1024
  120        1210    1210       0      2048
  180        1416    1418       2      2048
  240        1401    1474      73      2048
  300        1332    1533     201      2048

--- result ---
simulated 48.0 s of colony time in 360 rendered frames (time_scale 8)
population 1322, peak 1440, births 1600, deaths 278
capacity grew 2 times, now 2048
dropped substeps: 0
```

Видно повний життєвий цикл колонії: **ріст → двічі зростання ємності →
насичення зі смертністю → стабілізація**. Жодного відкинутого суб-кроку.

---

## 11.1. Компоненти

```gdscript
class ColonyCellStore extends EcsPackedStore:
    var position: PackedVector3Array = PackedVector3Array()
    var heading: PackedFloat32Array = PackedFloat32Array()
    var energy: PackedFloat32Array = PackedFloat32Array()
    var age: PackedFloat32Array = PackedFloat32Array()
    var crowding: PackedFloat32Array = PackedFloat32Array()

    func _init() -> void:
        track(&"position", &"heading", &"energy", &"age", &"crowding")
```

**Чому все в одному сховищі.** Ці п'ять полів читаються **разом**, кожного кроку,
тими самими системами. Рознести їх по п'яти сховищах означало б додати чотири
пошуки через `sparse_index` у найгарячіший цикл — і нічого не виграти
([розділ 4.8](04-komponenty-i-skhovyshcha.md#48-як-розкласти-дані-по-сховищах)).

**Чому `crowding` — це поле, а не обчислення на місці.** Просторовий запит
коштує дорого. Система руху вже питає сітку про сусідів, тому вона записує
кількість, а система метаболізму просто читає число. **Дорога операція
оплачується рівно один раз.** Це типовий і дуже вигідний прийом в ECS: одна
система готує дані для іншої через компонент.

```gdscript
var dividing := EcsTagStore.new()
```

**Чому тег, а не `bool` у сховищі.** Тег дає системі поділу **щільний список
саме тих клітин, що готові**. З полем `bool` вона мусила б переглядати всі 1400
клітин, щоб знайти десяток готових.

---

## 11.2. Порядок систем — і чому саме такий

```gdscript
scheduler.add_system(ColonyMovementSystem.new(),      PHASE_SIMULATION)
scheduler.add_system(ColonySpatialIndexSystem.new(),  PHASE_SIMULATION)
scheduler.add_system(ColonyMetabolismSystem.new(),    PHASE_SIMULATION)
scheduler.add_system(ColonyDivisionSystem.new(),      PHASE_SIMULATION)
scheduler.add_system(EcsReaperSystem.new(world),PHASE_SIMULATION)
scheduler.add_system(policy,                    PHASE_SIMULATION)
scheduler.add_system(ColonyStatisticsSystem.new(),    PHASE_STATISTICS)
```

Внутрішні класи прикладу мають префікс `Colony` (`ColonyMovementSystem` тощо): Godot забороняє внутрішньому класу мати те саме ім'я, що й глобальний `class_name` у проєкті, а `MovementSystem` / `SpatialIndexSystem` у реальній грі зазвичай зайняті.

Читайте цей список як алгоритм — це він і є:

1. **Movement** — усі зрушилися й дізналися свою скупченість.
2. **SpatialIndex** — індекс перебудовано **за новими** позиціями. Стояв би він
   перед рухом — усі запити наступного кроку працювали б за застарілими даними.
3. **Metabolism** — витрата енергії залежить від скупченості, яку щойно виміряв
   крок 1. Позначає голодних на знищення, ситих — тегом.
4. **Division** — ділить позначених.
5. **Reaper** — **єдина точка знищення**, і вона остання серед тих, хто торкається
   складу світу.
6. **CapacityPolicy** — одразу після жнеця, бо зростання переалокує всі буфери й
   вимагає, щоб ніхто не тримав щільний слот.
7. **Statistics** — після жнеця, тому бачить і народження, і смерті цього кроку.

---

## 11.3. Просторовий запит у циклі руху

```gdscript
var neighbours: int = grid.query_sphere(point, CROWD_RADIUS, MAX_NEIGHBOURS)
crowding[slot] = float(maxi(neighbours - 1, 0))
if neighbours > 1:
    var away := Vector3.ZERO
    for i in neighbours:
        if grid.query_buffer[i] == owners[slot]:
            continue                              # це я сам
        away += point - grid.query_point_buffer[i]
    if away.length_squared() > 0.0001:
        angle = AngleMath.approach(angle, atan2(away.x, away.z), 4.0 * delta)
```

Три речі, варті уваги:

- **`store_query_points = true`** вмикається один раз при налаштуванні сітки,
  і тоді `query_point_buffer` віддає позиції разом з ідентифікаторами. Без цього
  довелося б для кожного сусіда лізти в сховище через `index_of()`.
- **Себе треба відфільтрувати явно** — сітка не знає, хто питає.
- **`MAX_NEIGHBOURS = 16`** обмежує роботу в найщільніших місцях. Клітині в тисняві
  не потрібні всі сусіди, щоб зрозуміти, куди відштовхуватися.

---

## 11.4. Поділ: створення сутностей посеред кадру

```gdscript
var parents: int = mini(dividing.count, _context.spawn_buffer.size())
var born: int = world.create_entities(parents, _context.spawn_buffer)
if born <= 0:
    return
var first_slot: int = cells.count
cells.attach_many(_context.spawn_buffer, born)

var ready: PackedInt32Array = dividing.dense_entities
for i in born:
    var parent: int = ready[i]
    var parent_slot: int = cells.index_of(parent)
    if parent_slot == -1:
        continue
    var child_slot: int = first_slot + i
    ...
```

> **Чому створювати сутності посеред кадру безпечно, а знищувати — ні.**
>
> `attach()` тільки **дописує** в кінець щільного масиву. Він нічого не
> переміщує, тому жоден уже отриманий слот не псується, і цикл не збивається.
>
> `detach()`, навпаки, робить **swap-remove** — переносить останній елемент у
> звільнений слот. Ось чому знищення відкладене, а створення — ні.

Слоти дочірніх клітин ідуть підряд від `first_slot`, знятого **до**
`attach_many()`. Це і є той контракт, який робить пакетний спавн зручним.

```gdscript
dividing.clear()
```

`clear()` спорожнює тег **без жодної алокації** — просто заповнює `sparse_index`
значенням -1 і обнуляє `count`. Це набагато дешевше, ніж `detach()` на кожну
клітину.

---

## 11.5. Фіксований крок

```gdscript
var clock := SimulationClock.new()
clock.fixed_step = 1.0 / 30.0
clock.time_scale = 8.0
clock.max_substeps = 12
```

```gdscript
for frame in 360:
    var frame_delta: float = 1.0 / 60.0
    var substeps: int = clock.advance(frame_delta)

    scheduler.begin_frame()
    for step in substeps:
        scheduler.execute_phase(PHASE_SIMULATION, clock.fixed_step)
    scheduler.execute_phase(PHASE_STATISTICS, frame_delta)
```

При `time_scale = 8` і кадрі 1/60 накопичується 8/60 с, тобто **чотири** кроки по
1/30. Симуляція виконується чотири рази, статистика — один раз.

Без фіксованого кроку крок симуляції становив би 8/60 ≈ 0.133 с, і клітина з
порогом поділу `age >= 1.0` перескакувала б через нього нерівномірно, залежно
від частоти кадрів. З фіксованим кроком результат **відтворюваний**: та сама
сід-послідовність дає ту саму колонію на будь-якій машині.

`dropped substeps: 0` у виводі підтверджує, що запобіжник жодного разу не
спрацював — машина встигає.

---

## 11.6. Журнал змін замість подій

```gdscript
context.cells.track_changes = true
```

```gdscript
class ColonyStatisticsSystem extends EcsSystem:
    func execute(_delta: float) -> void:
        var cells: ColonyCellStore = _context.cells
        _context.births += cells.added_count
        _context.deaths += cells.removed_count
        _context.peak_population = maxi(_context.peak_population,
            _context.world.get_live_count())
        _context.world.clear_change_logs()
```

Система стоїть **після жнеця**, тому на цей момент `added_entities` містить усе,
що народилося цього кроку, а `removed_entities` — усе, що загинуло. Прочитавши
журнал, вона його чистить.

У справжній грі тут запускалися б звук смерті, партикли, оновлення UI.

---

## 11.7. Зростання ємності

```gdscript
policy.on_capacity_grown = func(_previous: int, next: int) -> void:
    context.resize_scratch(next)
    context.grid.configure(DISH_RADIUS, 0.0, cell_size, next)
```

Це найважливіший рядок усього прикладу з погляду типових помилок.

**Бібліотека збільшує лише свої буфери.** Усе, що гра виділила паралельно —
scratch-масиви для індексу, сама сітка, `MultiMesh`, мережеві буфери — треба
збільшити самому. Забути це означає, що після зростання світу індекс
будуватиметься лише за першими N клітинами, а решта стануть невидимими для
пошуку сусідів. Помилки при цьому не буде.

У виводі видно, що колбек спрацював двічі: 512 → 1024 → 2048.

---

## 11.8. Що показує профіль

```
  Movement          13743      ← 82% кадру
  SpatialIndex       1417
  Metabolism          612
  Division             10
  Reaper               11
  CapacityPolicy        1
  Statistics            3
```

Рух з'їдає більшість. Це очікувано: він робить **просторовий запит на кожну
клітину на кожен суб-крок** — 1300 клітин × 4 кроки ≈ 5200 запитів за кадр.

Якби це треба було оптимізувати, порядок дій був би такий
([розділ 9.4](09-produktyvnist.md#94-як-оптимізувати-правильно)):

1. **Не робити роботу.** Оновлювати скупченість не щокроку, а раз на 4 кроки —
   клітини не встигають далеко зміститися.
2. **Налаштування.** Зменшити `MAX_NEIGHBOURS` з 16 до 6.
3. **Менше сутностей.** Робити запит лише для клітин, близьких до порогу поділу.
4. **І лише потім** — мікрооптимізації самого циклу.

Профайлер тут не радить оптимізувати `Division` чи `Metabolism`, хоч би як
складно вони виглядали в коді. У цьому і сенс: **міряти, а не вгадувати**.

---

## 11.9. Що спробувати самостійно

Приклад зручний як пісочниця. Кілька вправ:

1. **Хижаки.** Заведіть другий тип клітин і тег `PredatorTag`. Хижак шукає
   найближчу здобич через `grid.query_nearest()`, наздоганяє і з'їдає її
   (`queue_destroy` + власна енергія). Куди в списку систем поставити полювання?
2. **Плями їжі.** Замініть сталу `FOOD_PER_SECOND` на другу просторову сітку з
   поживними плямами. Якому `cell_size` вона потребує, якщо плям 30, а клітин
   1300? (Підказка: [розділ 8.4](08-prostorovyi-poshuk.md#84-найважливіше-підбір-cell_size).)
3. **Мутації.** Додайте поле `division_threshold` і давайте дочірній клітині
   значення батька ± невеликий шум. Через кілька хвилин подивіться, яке значення
   перемогло.
4. **Прискорення.** Виставте `time_scale = 100`. Що покаже `dropped_substeps`?
   Що зміниться, якщо підняти `max_substeps` до 40?
5. **Пауза.** Додайте систему рендера з `requires_time = false` і переконайтеся,
   що на паузі вона працює, а симуляція стоїть.

---

## Головне з розділу

1. Тримайте разом те, що читається разом; дорогий запит оплачуйте один раз і
   зберігайте результат у компоненті.
2. Тег дає щільний список кандидатів — це дешевше за прапорець у сховищі.
3. **Створювати** сутності посеред кадру безпечно (append), **знищувати** — ні
   (swap-remove).
4. Фіксований крок робить симуляцію відтворюваною при будь-якому прискоренні.
5. При зростанні ємності **ваші власні буфери — ваша відповідальність**.
6. Профайлер вказує, що оптимізувати. Інтуїція — ні.

---

[← Типові помилки](10-typovi-pomylky.md) | [Зміст](README.md) | [Довідник API →](12-dovidnyk-api.md)
