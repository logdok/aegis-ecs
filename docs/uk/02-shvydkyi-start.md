[← Вступ до ECS](01-vstup-do-ecs.md) | [Зміст](README.md) | [Світ і сутності →](03-svit-sutnosti-zhyttievyi-tsykl.md)

---

# 2. Швидкий старт

---

## 2.1. Встановлення

1. Скопіюйте теку `addons/aegis_ecs/` у свій проєкт.
2. Готово.

Вмикати плагін у «Проєкт → Налаштування проєкту → Плагіни» **не потрібно**. Усі
класи оголошені через `class_name`, а Godot реєструє такі класи глобально просто
за фактом наявності файлу в проєкті. Пункт у списку плагінів існує лише для того,
щоб аддон був видимий і мав версію.

Перевірка, що все стало на місце:

```bash
godot --headless --script res://addons/aegis_ecs/example/minimal_example.gd
```

Має завершитися рядком `RESULT: OK`.

### Про конфлікт імен

Аддон займає такі глобальні імена:

`EcsWorld`, `EcsComponentStore`, `EcsPackedStore`, `EcsTagStore`, `EcsView`,
`EcsQuery`, `EcsSystem`, `EcsScheduler`, `EcsReaperSystem`,
`EcsCapacityPolicySystem`, `SimulationClock`, `UniformSpatialGrid`, `AngleMath`.

Якщо якесь із них у вашому проєкті вже зайняте, Godot повідомить про помилку —
перейменуйте `class_name` у відповідному файлі аддона. Усередині бібліотеки ці
імена ніде не використовуються рядком, тому перейменування безпечне.

### Що можна видалити

Модулі незалежні, зайве можна викинути:

| Тека | Що всередині | Залежить від |
|---|---|---|
| `ecs/` | Ядро: світ, сховища, системи, планувальник | нічого |
| `spatial/` | `UniformSpatialGrid` — пошук сусідів | нічого |
| `time/` | `SimulationClock` — фіксований крок і масштаб часу | нічого |
| `math/` | `AngleMath` — доворот кутів | нічого |
| `example/`, `tests/` | Приклад і самоперевірки | усе вище |

---

## 2.2. Повний робочий приклад

Ось симуляція цілком. 500 частинок розлітаються з центру, ті, що вийшли за
межу, знищуються. Це працює як є — скопіюйте у файл і запустіть.

```gdscript
extends SceneTree

# --- 1. Сховище компонентів ---------------------------------------------------
# Оголошуємо поля й називаємо їх один раз. Виділення пам'яті, зростання
# і перенесення даних при видаленні бібліотека бере на себе.

class Particles extends EcsPackedStore:
    var x: PackedFloat32Array = PackedFloat32Array()
    var y: PackedFloat32Array = PackedFloat32Array()
    var vx: PackedFloat32Array = PackedFloat32Array()
    var vy: PackedFloat32Array = PackedFloat32Array()

    func _init() -> void:
        track(&"x", &"y", &"vx", &"vy")


# --- 2. Контекст --------------------------------------------------------------
# Бібліотека нічого не знає про вашу гру: вона просто передає цей об'єкт
# кожній системі. Тримайте тут посилання на сховища й спільний стан.

class Context:
    var world: EcsWorld
    var particles: Particles
    var escaped: int = 0


# --- 3. Системи ---------------------------------------------------------------

class MovementSystem extends EcsSystem:
    var _context: Context

    func _init() -> void:
        system_name = "Movement"
        requires_time = true          # не запускати на паузі

    func setup(_world: EcsWorld, context) -> void:
        _context = context

    func execute(delta: float) -> void:
        var p: Particles = _context.particles
        # Локальні псевдоніми: звертатися до локальної змінної в циклі
        # помітно дешевше, ніж щоразу читати поле об'єкта.
        var x: PackedFloat32Array = p.x
        var y: PackedFloat32Array = p.y
        var vx: PackedFloat32Array = p.vx
        var vy: PackedFloat32Array = p.vy
        for slot in p.count:
            x[slot] += vx[slot] * delta
            y[slot] += vy[slot] * delta


class BoundsSystem extends EcsSystem:
    var _context: Context

    func _init() -> void:
        system_name = "Bounds"
        requires_time = true

    func setup(_world: EcsWorld, context) -> void:
        _context = context

    func execute(_delta: float) -> void:
        var p: Particles = _context.particles
        var x: PackedFloat32Array = p.x
        var owners: PackedInt32Array = p.dense_entities
        for slot in p.count:
            if absf(x[slot]) > 100.0:
                # Тільки позначає. Сутність доживе до кінця кадру,
                # тому обхід не розсиплеться на ходу.
                _context.world.queue_destroy(owners[slot])
                _context.escaped += 1


# --- 4. Складання та запуск ---------------------------------------------------

const TYPE_PARTICLE: int = 0

func _init() -> void:
    var context := Context.new()
    context.world = EcsWorld.new(1000)          # початкова ємність

    context.particles = Particles.new()
    context.world.register_store(context.particles, TYPE_PARTICLE)

    # Порядок реєстрації = порядок виконання = поведінка.
    var scheduler := EcsScheduler.new()
    scheduler.add_system(MovementSystem.new())
    scheduler.add_system(BoundsSystem.new())
    scheduler.add_system(EcsReaperSystem.new(context.world))   # завжди останній
    scheduler.setup_all(context.world, context)

    # Пакетне створення: один виклик замість 500.
    var ids := PackedInt32Array()
    ids.resize(500)
    var spawned: int = context.world.create_entities(500, ids)

    var first_slot: int = context.particles.count
    context.particles.attach_many(ids, spawned)

    var rng := RandomNumberGenerator.new()
    rng.seed = 12345
    for i in spawned:
        var slot: int = first_slot + i
        context.particles.x[slot] = 0.0
        context.particles.y[slot] = 0.0
        context.particles.vx[slot] = rng.randf_range(-40.0, 40.0)
        context.particles.vy[slot] = rng.randf_range(-40.0, 40.0)

    for frame in 600:
        scheduler.execute_all(1.0 / 60.0)

    print("залишилось: %d, вилетіло: %d"
        % [context.world.get_live_count(), context.escaped])
    quit(0)
```

Запуск:

```bash
godot --headless --script res://ваш_файл.gd
```

---

## 2.3. Розбір: що тут відбулося

### Крок 1 — сховище

```gdscript
class Particles extends EcsPackedStore:
    var x: PackedFloat32Array = PackedFloat32Array()
    ...
    func _init() -> void:
        track(&"x", &"y", &"vx", &"vy")
```

`EcsPackedStore` — рекомендована база для звичайних сховищ даних. Ви оголошуєте
типізовані поля й перелічуєте їхні імена. Все інше — виділення пам'яті під
ємність світу, зростання, перенесення даних при swap-remove — робиться за вас.

Поля залишаються звичайними типізованими членами, тож у гарячому циклі ви
читаєте `p.x` напряму, на повній швидкості. **Плати за зручність немає.**

> Є й нижчий рівень — `EcsComponentStore`, де ці операції пишуться руками.
> Він потрібен для екзотичних розкладок; для звичайних даних беріть
> `EcsPackedStore`. Подробиці — у [розділі 4](04-komponenty-i-skhovyshcha.md).

### Крок 2 — контекст

Бібліотека **не знає про вашу гру нічого**. Вона передає системам об'єкт
`context` як є, і саме там ви тримаєте посилання на сховища.

Це навмисно: завдяки цьому аддон переносний між проєктами без жодної правки.

### Крок 3 — системи

Три речі, на які варто звернути увагу:

1. **`system_name`** задається в `_init()` — воно потрапляє у профілювання.
2. **`requires_time = true`** означає «не запускати мене, коли час стоїть».
   Пауза в цій бібліотеці — це нульовий крок, а не пропуск кадру, щоб рендер і
   HUD продовжували працювати.
3. **Локальні псевдоніми масивів** перед циклом. У Godot 4 `Packed*Array`
   передаються **за посиланням**, тож записи через псевдонім одразу потрапляють у
   сховище — присвоювати назад нічого не треба.

### Крок 4 — складання

```gdscript
scheduler.add_system(MovementSystem.new())
scheduler.add_system(BoundsSystem.new())
scheduler.add_system(EcsReaperSystem.new(context.world))
```

`EcsReaperSystem` — це та сама «одна точка знищення» з
[розділу 1.7](01-vstup-do-ecs.md#17-чому-знищення-відкладене), оформлена як
готовий клас. **Ставте його останнім і рівно один раз** у конвеєрі.

### Пакетне створення

```gdscript
var spawned: int = context.world.create_entities(500, ids)
var first_slot: int = context.particles.count
context.particles.attach_many(ids, spawned)
```

`create_entities()` і `attach_many()` роблять за один виклик те, на що інакше
пішло б 500. У замірах це **у 2.4 раза швидше** за поелементний спавн.

Слоти новоприкріплених компонентів ідуть підряд, починаючи зі значення `count`,
знятого **до** виклику, — тому дані можна писати одразу за індексом
`first_slot + i`.

---

## 2.4. Кадр у реальній грі

У прикладі вище кадр крутиться в циклі `for`. У справжній грі це виглядає так:

```gdscript
extends Node3D

var _context: Context
var _scheduler: EcsScheduler

func _ready() -> void:
    # ...побудова світу, як у прикладі...
    pass

func _process(delta: float) -> void:
    var step: float = 0.0 if _paused else minf(delta, 0.1)
    _scheduler.execute_all(step)
```

Два зауваження:

- **Пауза — це `0.0`, а не пропуск виклику.** Системи з `requires_time = true`
  планувальник пропустить сам, а рендер і камера працюватимуть далі.
- **`minf(delta, 0.1)`** обмежує крок: якщо гра підвисла на секунду, без цього
  обмеження всі об'єкти телепортуються. Для серйозної симуляції візьміть
  натомість `SimulationClock` — див. [розділ 7](07-chas-podii-yemnist.md).

---

## 2.5. Куди далі

- Не зрозуміло, чому сутність — це число, і що таке handle →
  [розділ 3](03-svit-sutnosti-zhyttievyi-tsykl.md)
- Потрібне сховище зі складнішими даними, або з `Resource` усередині →
  [розділ 4](04-komponenty-i-skhovyshcha.md)
- Треба обробляти не всі сутності, а лише з певним набором компонентів →
  [розділ 6](06-poshuk-sutnostei.md)
- Потрібно прискорювати або сповільнювати час без розсинхрону →
  [розділ 7](07-chas-podii-yemnist.md)
- Потрібно шукати сусідів («хто поруч») → [розділ 8](08-prostorovyi-poshuk.md)

---

[← Вступ до ECS](01-vstup-do-ecs.md) | [Зміст](README.md) | [Світ і сутності →](03-svit-sutnosti-zhyttievyi-tsykl.md)
