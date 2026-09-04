[← Світ і сутності](03-svit-sutnosti-zhyttievyi-tsykl.md) | [Зміст](README.md) | [Системи →](05-systemy-i-planuvalnyk.md)

---

# 4. Компоненти і сховища

Сховище (`store`) — це контейнер даних одного типу компонента для всіх
сутностей. Саме тут живе вся розкладка пам'яті, заради якої існує ECS.

---

## 4.1. Як влаштоване сховище

Кожне сховище — це **sparse set** із двох масивів у протилежних напрямках:

```
sparse_index[entity_id] → щільний слот, або -1, якщо компонента немає
dense_entities[slot]    → якій сутності належить цей слот
```

Плюс масиви **самих даних**, індексовані **тим самим щільним слотом**.

```gdscript
var slot: int = positions.index_of(entity)   # entity 42 → slot 5
if slot != -1:
    print(positions.x[slot])                 # дані шукаємо за 5, а не за 42
```

> **Найчастіша помилка новачка:** індексувати масив даних ідентифікатором
> сутності. `positions.x[42]` — це майже завжди чужий компонент або сміття.
> Дані адресуються **слотом**, не id.

Три поля навмисно публічні: `sparse_index`, `dense_entities` і `count`. Системи
читають їх напряму в гарячих циклах, а виклик методу в GDScript коштує в кілька
разів дорожче за читання елемента масиву (заміряно: ~90 нс проти ~20 нс). Ззовні
класу вважайте їх **тільки для читання**.

---

## 4.2. `EcsPackedStore` — рекомендований спосіб

```gdscript
class_name EnemyStore
extends EcsPackedStore

var position: PackedVector3Array = PackedVector3Array()
var health: PackedFloat32Array = PackedFloat32Array()
var speed: PackedFloat32Array = PackedFloat32Array()
var tint: PackedColorArray = PackedColorArray()

func _init() -> void:
    track(&"position", &"health", &"speed", &"tint")
```

Це все. Ви оголошуєте типізовані поля й називаєте їх один раз — виділення
пам'яті, зростання ємності та перенесення даних при видаленні реалізовані
базовим класом.

**Підтримувані типи полів:** будь-який `Packed*Array`, а також звичайний `Array`
для полів з об'єктами чи ресурсами.

### Чому це не повільніше

Поля залишаються звичайними типізованими членами класу. У гарячому циклі ви
читаєте їх напряму:

```gdscript
var hp: PackedFloat32Array = enemies.health
for slot in enemies.count:
    hp[slot] -= poison_damage
```

Узагальнена робота відбувається лише під час виділення пам'яті та видалення. І
навіть там `EcsPackedStore` **не програє** ручному сховищу: він реалізує пакетне
перенесення, яке дістає масиви по одному разу на всю операцію, а не на кожен
переміщений елемент. У замірах (розділ 9) знищення 10 000 сутностей із чотирма
компонентами: ручне сховище — 7.55 мс, декларативне — 7.58 мс. Різниця в межах
похибки.

### Корисні методи

```gdscript
store.get_tracked_field_count()      # скільки полів зареєстровано
store.clear_slot(slot)               # записати нулі в усі поля цього слота
store.refresh_tracked_arrays()       # якщо поле присвоїли цілком заново
```

`clear_slot()` варто викликати одразу після `attach()`, якщо у сховища є
необов'язкові поля, які шлях створення не завжди заповнює: слоти
перевикористовуються, і свіжий компонент інакше починає життя зі сміттям
попереднього власника.

`refresh_tracked_arrays()` потрібен лише у рідкісному випадку, коли поле
**присвоїли цілком** (`health = PackedFloat32Array()`), а не змінювали на місці.

---

## 4.3. `EcsTagStore` — компонент без даних

Іноді системі не треба знати про сутність нічого, крім самого факту
приналежності до категорії: «це ворог», «це снаряд», «це можна підібрати».

```gdscript
var hostile_tag := EcsTagStore.new()
world.register_store(hostile_tag, TYPE_HOSTILE)

hostile_tag.attach(entity)
if hostile_tag.has(entity):
    ...

# Найцінніше — щільний обхід усієї категорії:
var hostiles: PackedInt32Array = hostile_tag.dense_entities
for i in hostile_tag.count:
    var enemy: int = hostiles[i]
```

Тег не має масивів даних, тому його видалення взагалі не переносить нічого — це
найдешевше сховище в бібліотеці.

---

## 4.4. `EcsComponentStore` — ручне сховище

Нижчий рівень. Потрібен, коли розкладка нестандартна: наприклад, поле-бітова
маска, дані у власному форматі або payload, який треба переносити нетривіально.

Спадкоємець **зобов'язаний** реалізувати два методи:

```gdscript
class_name CustomStore
extends EcsComponentStore

var packed_flags: PackedInt32Array = PackedInt32Array()

# 1. Виділити свої масиви під ємність світу.
func _reserve_dense(dense_capacity: int) -> void:
    packed_flags.resize(dense_capacity)

# 2. Перенести дані при swap-remove.
func _relocate_dense(from_slot: int, to_slot: int) -> void:
    packed_flags[to_slot] = packed_flags[from_slot]
```

> **Забути `_relocate_dense()` — класична помилка.** Видалення почне тихо
> втрачати дані: на місце видаленого приїде останній елемент, але його payload
> залишиться на старому місці. Жодного повідомлення в консолі не буде.
> Саме тому для звичайних даних існує `EcsPackedStore`.

---

## 4.5. Необов'язкові хуки

Ці методи **навмисно не оголошені** в базовому класі. Бібліотека визначає їхню
наявність через `has_method()`: **визначили — використовується, не визначили —
не коштує нічого**. Прапорця, який можна забути виставити, тут немає.

| Хук | Навіщо |
|---|---|
| `_grow_dense(prev, next)` | Дозволяє `world.reserve_capacity()`. Має зберегти всі дані в `[0, count)`. |
| `_relocate_dense_batch(from, to, n)` | Пакетне перенесення: дістати масиви один раз на всю операцію. |
| `_release_dense(slot)` | Звільнити `Resource`/`RID`/`Callable` перед перезаписом. |
| `_clear_relocated_dense(slot)` | Очистити дублікат у слоті, звідки дані переїхали. |
| `_clear_dense(active_count)` | Масове очищення при `clear()`/`reset()`. |

`EcsPackedStore` і `EcsTagStore` вже визначають `_grow_dense`, тому підтримують
зростання ємності без будь-яких дій з вашого боку.

### Зростання ємності для ручного сховища

```gdscript
func _grow_dense(_previous_capacity: int, dense_capacity: int) -> void:
    packed_flags.resize(dense_capacity)     # resize зберігає префікс [0, count)
```

Перевірити можна так:

```gdscript
if store.supports_capacity_growth():
    ...
```

Якщо хоча б одне зареєстроване сховище не має `_grow_dense`,
`world.reserve_capacity()` поверне `false`, **не змінивши нічого**.

---

## 4.6. Компоненти з володінням ресурсами

Якщо payload містить `Resource`, `RID`, `Callable` або `Object`, недостатньо
просто перенести значення — треба ще й звільнити те, що видаляється.

```gdscript
class_name MaterialStore
extends EcsPackedStore

var materials: Array = []          # звичайний Array для об'єктів

func _init() -> void:
    track(&"materials")

# Викликається на слоті, який ВИДАЛЯЄТЬСЯ, ДО перенесення даних.
func _release_dense(dense_slot: int) -> void:
    var rid = materials[dense_slot]
    if rid != null:
        RenderingServer.free_rid(rid)
    materials[dense_slot] = null

# Викликається на слоті, ЗВІДКИ дані переїхали.
# Тут ТІЛЬКИ очищаємо дублікат — володіння вже перейшло на нове місце.
func _clear_relocated_dense(dense_slot: int) -> void:
    materials[dense_slot] = null

# Масове очищення при clear() / world.reset().
func _clear_dense(active_count: int) -> void:
    for slot in active_count:
        if materials[slot] != null:
            RenderingServer.free_rid(materials[slot])
            materials[slot] = null
```

**Порядок має значення.** `detach()` спочатку викликає `_release_dense()` на
слоті, що видаляється, і лише потім переносить payload з останнього слота та
викликає `_clear_relocated_dense()`. Змішати ці дві операції — означає або
витік ресурсу, або подвійне звільнення.

Якщо ви визначите `_clear_relocated_dense()` без `_release_dense()`, бібліотека
надрукує помилку при реєстрації сховища: це майже завжди означає витік.

---

## 4.7. Основні операції

```gdscript
var slot: int = store.attach(entity)     # ідемпотентно; -1 при переповненні
store.detach(entity)                     # безпечно, навіть якщо компонента немає

store.has(entity)                        # bool
store.index_of(entity)                   # слот або -1
store.entity_at(slot)                    # сутність, якій належить слот
store.count                              # скільки компонентів
store.clear()                            # спорожнити без алокацій
```

> `has()`, `index_of()` і `entity_at()` **навмисно не перевіряють межі** — це
> примітиви гарячого циклу. Передати сюди id неіснуючої сутності — помилка
> викликального коду. Структурні входи (`attach`, `detach` та їхні пакетні
> форми) межі перевіряють, бо виконуються значно рідше.

### Пакетні операції

```gdscript
var first: int = store.count
var attached: int = store.attach_many(ids, count)
# нові слоти: [first, first + attached)

var removed: int = store.detach_many(ids, count)
```

`attach_many()` пропускає сутності, у яких компонент уже є, тому `attached` може
бути меншим за `count`.

---

## 4.8. Як розкласти дані по сховищах

Практичне питання: одне велике сховище чи багато маленьких?

**Тримайте разом те, що читається разом.** Якщо система руху щокадру читає
позицію і швидкість, є сенс покласти їх в одне сховище: тоді не потрібен
пошук через `sparse_index`, обхід іде по одному щільному масиву.

**Розділяйте те, що використовується рідко або окремо.** Компонент, який має
кожна десята сутність, у спільному сховищі змусив би решту дев'ять носити
незаповнені поля — і, що гірше, зайняв би місце в лініях кешу гарячого циклу.

**Ознаки-прапорці виносьте в теги.** «Оглушений», «невразливий», «у воді» — це
`EcsTagStore`, а не `bool` у великому сховищі: тег дає щільний список саме тих,
кого це стосується.

Приклад розкладки для гри:

| Сховище | Поля | Хто читає |
|---|---|---|
| `Transform` | position, yaw | майже всі системи |
| `Locomotion` | velocity, speed | рух, наведення |
| `Health` | current, max | урон, смерть |
| `MissileLauncher` | cooldown, range | тільки система стрільби (мало сутностей) |
| `HostileTag` | — | спавн, пошук цілей |
| `StunnedTag` | — | рух (виключення) |

---

## Головне з розділу

1. Дані адресуються **щільним слотом**, а не id сутності.
2. Для звичайних даних беріть **`EcsPackedStore`** — жодного шаблонного коду
   і жодної втрати швидкості.
3. `EcsTagStore` — для ознак без даних.
4. Ручне `EcsComponentStore` **зобов'язане** реалізувати `_reserve_dense` і
   `_relocate_dense`.
5. Необов'язкові хуки **визначаються автоматично**: визначили — працює.
6. Сховища з `Resource`/`RID` реалізують `_release_dense` **і**
   `_clear_relocated_dense` — порядок їх виклику критичний.
7. Разом читається — разом і зберігайте; рідкісне й окреме виносьте.

---

[← Світ і сутності](03-svit-sutnosti-zhyttievyi-tsykl.md) | [Зміст](README.md) | [Системи →](05-systemy-i-planuvalnyk.md)
