[← Системи](05-systemy-i-planuvalnyk.md) | [Зміст](README.md) | [Час і події →](07-chas-podii-yemnist.md)

---

# 6. Пошук потрібних сутностей

Типова система обробляє не всі сутності, а ті, що мають певний набір
компонентів: «усі, хто має позицію І швидкість, але НЕ оглушений».

У Aegis для цього є три рівні, від найшвидшого до найзручнішого. Це не «поганий,
середній і хороший спосіб» — це три різні компроміси, і кожен доречний у своєму
місці.

---

## 6.1. Рівень 1: прямий цикл (найшвидший)

Ідея проста: **вести обхід по щільному масиву найменшого зі сховищ**, а решту
компонентів добирати через `sparse_index`.

```gdscript
func execute(delta: float) -> void:
    var velocities: VelocityStore = _context.velocities
    var positions: PositionStore = _context.positions

    # Локальні псевдоніми — обов'язково перед циклом.
    var owners: PackedInt32Array = velocities.dense_entities
    var pos_slots: PackedInt32Array = positions.sparse_index
    var vx: PackedFloat32Array = velocities.x
    var px: PackedFloat32Array = positions.x

    for dense in velocities.count:
        var slot: int = pos_slots[owners[dense]]
        if slot < 0:
            continue                      # у цієї сутності немає позиції
        px[slot] += vx[dense] * delta
```

**Чому вести саме по найменшому сховищу.** Якщо швидкість мають 300 сутностей, а
позицію — 10 000, то обхід по швидкостях дає 300 ітерацій, а по позиціях — 10 000
з 9 700 марними перевірками.

**Коли використовувати.** У найгарячіших системах із відомою наперед схемою. Це
основний робочий інструмент бібліотеки: заміряно ~57 нс на елемент разом із
пошуком другого компонента.

Абстракції запиту в ядрі навмисно немає саме тому, що на 10 000 сутностей × 12
систем вона була б помітна в профілі.

---

## 6.2. Рівень 2: `EcsView` (без алокацій)

Коли набір компонентів складніший, ніж «два конкретні сховища», або коли
потрібні **виключення**, зручніше описати умову декларативно.

```gdscript
var _moving := EcsView.new()

func setup(world: EcsWorld, context) -> void:
    _moving.configure(
        world,
        PackedInt32Array([TYPE_POSITION, TYPE_VELOCITY]),   # обов'язкові
        PackedInt32Array([TYPE_STUNNED]),                   # виключені
        self,                                               # власник (для валідації)
    )

func execute(delta: float) -> void:
    _moving.refresh_driver()                    # обрати найменше сховище
    var driver := _moving.get_candidate_store()
    var candidates: PackedInt32Array = driver.dense_entities

    for dense in driver.count:
        var entity: int = candidates[dense]
        if not _moving.matches(entity):
            continue
        # ...
```

`EcsView` **нічого не матеріалізує й нічого не алокує**. `configure()` —
холодна операція (один раз у `setup`), `refresh_driver()` обирає найменше з
обов'язкових сховищ, а `matches()` робить прямі перевірки sparse-множин.

### Швидший варіант: вбудувати перевірку

`matches()` — це виклик методу на кожного кандидата, а виклик у GDScript коштує
~90 нс. У гарячій системі краще взяти у View тільки **розв'язані масиви** і
вбудувати перевірку у власний цикл:

```gdscript
_moving.refresh_driver()
var driver := _moving.get_candidate_store()
var candidates: PackedInt32Array = driver.dense_entities
var health_slots: PackedInt32Array = _moving.get_required_sparse(1)
var stunned_slots: PackedInt32Array = _moving.get_excluded_sparse(0)

for dense in driver.count:
    var entity: int = candidates[dense]
    var health_slot: int = health_slots[entity]
    if health_slot == -1 or stunned_slots[entity] != -1:
        continue
    # ...
```

Так ви отримуєте зручність опису й швидкість прямого циклу одночасно.
`get_driver_required_index()` підкаже, яке саме сховище стало ведучим — його
перевіряти не треба, приналежність до нього гарантована самим обходом.

---

## 6.3. Рівень 3: `EcsQuery` (кешований результат)

`EcsQuery` **матеріалізує** перетин у заздалегідь виділений буфер і перебудовує
його лише тоді, коли склад учасників справді змінився.

```gdscript
var _query := EcsQuery.new()

func setup(world: EcsWorld, context) -> void:
    _query.configure(
        world,
        PackedInt32Array([TYPE_POSITION, TYPE_HEALTH]),
        PackedInt32Array([TYPE_INVULNERABLE]),
        self,
    )

func execute(_delta: float) -> void:
    _query.refresh()                     # перебудує, тільки якщо треба
    for index in _query.count:
        var entity: int = _query.entity_at(index)
        # ...
```

`refresh()` повертає `true`, якщо кеш було перебудовано, і `false`, якщо склад
не змінився. Він відстежує `structural_version` кожного сховища-учасника.

**Що інвалідує кеш:** `attach`, `detach`, `clear`, зростання ємності.
**Що НЕ інвалідує:** запис у payload. Змінили здоров'я — склад запиту той самий.

Це і є сенс `EcsQuery`: якщо перетин читають кілька систем або він змінюється
рідко, перебудова просто не відбувається. У замірах промах кешу коштує ~0.9 мс на
10 000 кандидатів, а **попадання — 0.001 мс**.

### Обмеження розміру буфера

Типово результат виділяється на `world.capacity`. Для вузького запиту це
марнотратно:

```gdscript
_query.configure(world, required, excluded, self, 256)   # максимум 256 результатів

_query.refresh()
if _query.is_truncated():
    push_warning("результат обрізано — підходило більше за 256")
```

Без ліміту кожен запит займає приблизно `4 байти × capacity`. Сто повних запитів
при ємності 1 000 000 — це близько 381 МіБ. Для великої схеми або ставте ліміти,
або користуйтеся View/прямим циклом.

### Швидкий доступ до буфера

```gdscript
var entities: PackedInt32Array = _query.get_entities_unsafe()
for index in _query.count:
    var entity: int = entities[index]
```

Прибирає виклик методу на елемент. Буфер вважається **тільки для читання**, і
псевдонім не можна зберігати через `refresh()` або `reserve_capacity()`.

---

## 6.4. Як обрати

| | Прямий цикл | `EcsView` | `EcsQuery` |
|---|---|---|---|
| Швидкість обходу | найвища | висока | найвища (по буферу) |
| Вартість підготовки | нема | `refresh_driver()` | `refresh()`, іноді перебудова |
| Алокації | нема | нема | буфер один раз |
| Виключення компонентів | руками | так | так |
| Коли брати | гаряча система, фіксована схема | змінна схема, виключення | перетин читають кілька разів або він рідко змінюється |

Практична порада: **починайте з прямого циклу**. Переходьте на View, коли умова
стає складною й код перестає читатися; на Query — коли профайлер показує, що той
самий перетин будується кілька разів за кадр.

---

## 6.5. Обмеження, спільне для View і Query

Обидва вимагають **щонайменше один обов'язковий тип**. Світ навмисно не тримає
другого щільного списку «всіх живих» тільки заради запиту без компонентів.

Якщо треба обійти справді всіх — заведіть тег, який має кожна сутність, і ведіть
обхід по ньому.

---

## 6.6. Правило безпеки

**Не змінюйте склад сховищ-учасників посеред активного обходу.**

```gdscript
# НЕПРАВИЛЬНО
for dense in positions.count:
    var entity: int = positions.dense_entities[dense]
    if should_remove(entity):
        positions.detach(entity)      # swap-remove зсунув масив під ногами
```

Правильно — позначити й прибрати пізніше:

```gdscript
for dense in positions.count:
    var entity: int = positions.dense_entities[dense]
    if should_remove(entity):
        world.queue_destroy(entity)   # знищить EcsReaperSystem наприкінці кадру
```

Якщо треба зняти саме **компонент**, а не сутність, — зберіть їх у буфер і
викличте `detach_many()` після циклу.

---

## Головне з розділу

1. **Прямий цикл** — основний інструмент; вести обхід по найменшому сховищу.
2. **`EcsView`** — декларативний опис без алокацій; для швидкості беріть із
   нього sparse-масиви й вбудовуйте перевірку самі.
3. **`EcsQuery`** — коли перетин читають багато разів або він рідко змінюється;
   промах ~0.9 мс, попадання ~0.001 мс.
4. Запис у payload **не** інвалідує кеш запиту; `attach`/`detach` — інвалідує.
5. Ніколи не змінюйте склад сховища посеред обходу.

---

[← Системи](05-systemy-i-planuvalnyk.md) | [Зміст](README.md) | [Час і події →](07-chas-podii-yemnist.md)
