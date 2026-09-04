[← Компоненти](04-komponenty-i-skhovyshcha.md) | [Зміст](README.md) | [Пошук сутностей →](06-poshuk-sutnostei.md)

---

# 5. Системи і планувальник

---

## 5.1. Анатомія системи

```gdscript
class_name MovementSystem
extends EcsSystem

var _context: Context              # ваш власний клас

func _init() -> void:
    system_name = "Movement"       # потрапляє у профілювання
    requires_time = true           # не запускати, коли час стоїть

func setup(_world: EcsWorld, context) -> void:
    _context = context             # кешуємо посилання один раз

func execute(delta: float) -> void:
    # робота з даними
    pass
```

### `setup()`

Викликається **один раз**, коли всі сховища зареєстровані й весь конвеєр
зібраний. Це правильне місце, щоб зберегти посилання на контекст або на конкретні
сховища.

Кешувати тут посилання — не порушення принципу «системи не зберігають даних»:
кешується **посилання** на існуюче сховище, а не копія даних.

Параметр `context` навмисно **не типізований**: бібліотека нічого не знає про
вашу гру. Присвойте його типізованому полю у своїй системі — і далі працюйте зі
статичною типізацією.

### `execute()`

Викликається раз на кадр, у порядку, заданому планувальником.

### `teardown()`

Викликається `scheduler.teardown_all()` у **зворотному** порядку реєстрації —
ресурси розбираються як стек відносно `setup()`.

---

## 5.2. Порядок реєстрації — це контракт

```gdscript
scheduler.add_system(SpawnSystem.new())          # 1
scheduler.add_system(MovementSystem.new())       # 2
scheduler.add_system(SpatialIndexSystem.new())   # 3
scheduler.add_system(CollisionSystem.new())      # 4
scheduler.add_system(DamageSystem.new())         # 5
scheduler.add_system(EcsReaperSystem.new(world)) # 6
```

Планувальник **ніколи не сортує системи**. Порядок реєстрації — повна
специфікація поведінки.

Правило: **якщо система Б читає те, що система А пише в цьому ж кадрі, А
реєструється раніше.**

У прикладі вище індекс сусідів (3) перебудовується **після** руху (2) і
**до** пошуку зіткнень (4). Поміняйте 2 і 3 місцями — зіткнення шукатимуться за
позиціями минулого кадру. Помилки не буде; буде інша гра.

Ставтеся до цього списку як до алгоритму, а не як до оформлення. У серйозному
проєкті варто написати коментар біля кожного рядка з поясненням, чому система
стоїть саме тут.

---

## 5.3. Пауза і `requires_time`

Пауза в цій бібліотеці — це **нульовий крок**, а не пропуск кадру:

```gdscript
scheduler.execute_all(0.0)      # пауза
```

Так рендер, камера, HUD і ввід продовжують працювати, а симуляція стоїть.

Щоб система, залежна від часу, не виконувалася на паузі, оголосіть це один раз:

```gdscript
func _init() -> void:
    system_name = "Movement"
    requires_time = true
```

Планувальник пропустить виклик повністю.

| `requires_time` | Для чого |
|---|---|
| `true` | Рух, таймери, кулдауни, старіння, AI, фізика — усе, що вимірюється в секундах |
| `false` (типово) | Рендер, камера, HUD, ввід, вивантаження буферів, **жнець** |

> **`EcsReaperSystem` навмисно має `requires_time = false`.** Сутності, позначені
> на знищення перед паузою, мають бути прибрані, інакше вони висітимуть у черзі
> й у всіх сховищах увесь час паузи.

---

## 5.4. Фази

Фаза — це **мітка й фільтр**, а не спосіб упорядкування. Планувальник як не
сортував системи, так і не сортує.

```gdscript
const PHASE_INPUT: int = 100
const PHASE_SIMULATION: int = 200
const PHASE_PRESENTATION: int = 300

scheduler.add_system(InputSystem.new(), PHASE_INPUT)
scheduler.add_system(MovementSystem.new(), PHASE_SIMULATION)
scheduler.add_system(CollisionSystem.new(), PHASE_SIMULATION)
scheduler.add_system(RenderUploadSystem.new(), PHASE_PRESENTATION)
```

Звичайний кадр:

```gdscript
scheduler.execute_all(delta)
```

Кадр із фіксованим кроком, де симуляція виконується кілька разів, а рендер —
один (див. [розділ 7](07-chas-podii-yemnist.md)):

```gdscript
scheduler.begin_frame()                       # закрити попередній кадр
for i in substeps:
    scheduler.execute_phase(PHASE_SIMULATION, clock.fixed_step)
scheduler.execute_phase(PHASE_PRESENTATION, delta)
```

`begin_frame()` обов'язковий перед серією `execute_phase()`: він завершує
вимірювання попереднього кадру й обнуляє лічильники. `execute_all()` викликає
його сам.

**Заміри часу накопичуються** між двома `begin_frame()`. Тому кадр із чотирма
суб-кроками покаже сумарну вартість цих чотирьох викликів — тобто саме те, що
реально потрапило в бюджет кадру.

### Вимикачі

```gdscript
scheduler.set_system_enabled(index, false)   # вимкнути одну систему
scheduler.set_phase_enabled(PHASE_AI, false) # вимкнути цілу групу
scheduler.set_system_phase(index, phase)     # перенести систему в іншу фазу
var index: int = scheduler.find_system("Movement")
```

Вимкнена система зберігає свій індекс у профайлері (щоб таблиця не «стрибала»)
і показує нульовий час.

Поле `system_phase` **заморожується після `add_system()`**. Змінювати фазу можна
лише через `scheduler.set_system_phase()` — так стан «увімкнено/вимкнено» фази не
розходиться з системою.

Один екземпляр `EcsSystem` належить **одному** планувальнику. Для іншого конвеєра
створіть новий екземпляр.

---

## 5.5. Профілювання

Головний інструмент діагностики продуктивності — просто прямо на пристрої.

```gdscript
for i in scheduler.get_system_count():
    print("%-24s %6d мкс   (сер. %6d)" % [
        scheduler.get_system_name(i),
        int(scheduler.get_timing_usec(i)),
        int(scheduler.get_average_timing_usec(i)),
    ])
```

- `get_timing_usec(i)` — час за **останній кадр**. Стрибає.
- `get_average_timing_usec(i)` — експоненційно згладжене значення. Саме його
  варто виводити на екранний оверлей: воно читабельне.
- `get_total_timing_usec()` — сума за кадр.
- `was_system_executed(i)` — чи виконувалася система (вимкнена або пропущена
  через `requires_time` поверне `false`).
- `reset_profiling()` — обнулити все.

Вимірювання в **мікросекундах**, а не мілісекундах, навмисно: дешеві системи
вкладаються в одиниці мікросекунд, і мілісекундний звіт складався б із нулів.

Саме вимірювання коштує два виклики таймера на систему за кадр. Якщо треба
вичавити останнє:

```gdscript
scheduler.profiling_enabled = false
```

### Приклад реального звіту

Це вивід із гри на 14 систем (Aegis Core, 600 кадрів, ~57 живих сутностей):

```
  EnemySpawn                              0   avg      0
  SpatialIndex                          338   avg    336     ← 75% кадру
  MissileSpatialIndex                     6   avg      6
  TurretTargeting                        41   avg     34
  ProjectileImpact                       54   avg     55
  EntityReaper                            1   avg      4
```

Одразу видно, куди дивитися: `SpatialIndex` з'їдає три чверті кадру. Це і є
сенс профайлера — не гадати, а бачити.

---

## 5.6. Метадані доступу

Необов'язковий опис того, що система читає й пише. **Не впливає ні на порядок,
ні на швидкість** — використовується інструментами.

```gdscript
func _init() -> void:
    system_name = "Movement"
    requires_time = true
    declare_read(TYPE_VELOCITY)
    declare_write(TYPE_POSITION)
    declare_structural_write(TYPE_SLEEPING)   # attach/detach цього типу
    writes_world_structure = true             # create/destroy/reset
    complete_access_metadata()                # «опис повний»
```

Навіщо:

```gdscript
scheduler.validate_pipeline(world)      # чи всі типи зареєстровані, чи не спадають фази
scheduler.systems_conflict(a, b)        # чи можна було б виконати паралельно
view.validate_owner_access()            # чи оголосила система те, що читає через View
```

`systems_conflict()` — консервативний аналіз залежностей. Доки система не
викликала `complete_access_metadata()`, її доступ вважається **невідомим**, і
вона конфліктує з усіма — щоб старий код не потрапив випадково в небезпечний
паралельний батч.

`writes_world_structure = true` завжди конфліктує з усіма: створення й знищення
змінюють валідність сирих id і всіх View.

> Поточний планувальник **послідовний**. Метадані — це підготовлений ґрунт, а не
> працююча багатопотоковість. Не розраховуйте на автоматичне розпаралелювання.

---

## 5.7. Готові системи

### `EcsReaperSystem`

Та сама «одна точка знищення»:

```gdscript
var reaper := EcsReaperSystem.new(world)
scheduler.add_system(reaper)      # останньою

# після кадру:
reaper.last_reaped      # скільки знищено цього кадру
reaper.total_reaped     # скільки всього
```

`last_reaped` зручний, щоб запускати звук чи ефект смерті: він каже, скільки
сутностей загинуло, не змушуючи їх рахувати вручну.

### `EcsCapacityPolicySystem`

Автоматичне зростання світу — див.
[розділ 7.3](07-chas-podii-yemnist.md#73-ємність-і-політика-зростання).

---

## Головне з розділу

1. `setup()` — кешувати посилання; `execute()` — робота; `teardown()` —
   у зворотному порядку.
2. **Порядок реєстрації — це поведінка**, а не оформлення.
3. Пауза — це `delta == 0`; система оголошує `requires_time = true`, і
   планувальник пропустить її сам.
4. Фази — фільтр і мітка; сортування не відбувається ніколи.
5. Заміри накопичуються між `begin_frame()`, тому суб-кроки сумуються коректно.
6. Метадані доступу нічого не змінюють у виконанні — вони для валідації.
7. `EcsReaperSystem` — останнім і рівно один.

---

[← Компоненти](04-komponenty-i-skhovyshcha.md) | [Зміст](README.md) | [Пошук сутностей →](06-poshuk-sutnostei.md)
