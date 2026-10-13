# Что видит агент (операции чтения)

Ответы — компактный JSON, координаты округлены до 0.1, качество только `normal`.
Два уровня обзора (PROTOCOL §6.7): **статичное** — в открытых (`is_chunk_charted`) чанках,
**живое** (враги, содержимое контейнеров/машин, предметы на земле) — только в видимых
(`is_chunk_visible`). Каждая операция — `M.ops.<op>` в `scripts/perception/<файл>.lua`,
`ctx = {helper_id?, entity?}`. Центр по умолчанию — **помощник**; `near:"player"` — хозяин
(`physical_position`, иначе `no_player`). Владелец — поток G, кроме `rates` (L).

## `state` (h)
```json
{"helper":"h1","surface":"vulcanus","pos":{"x":52.4,"y":93.4},"health":250,"max_health":250,
 "reach":{"build":10,"reach":10,"resource":2.7,"pickup":1},
 "inv":{"iron-plate":40,"coal":12},"inv_free":72,"armor":"power-armor-mk2",
 "robots":{"construction":10,"available":9},
 "job":{"job":57,"do":"walk","progress":[12,40]},"queue":2,
 "players":[{"name":"Tartaluga","owner":true,"online":true,"surface":"vulcanus","pos":{"x":48,"y":90},"dist":4.2}],
 "near":{"enemies":[],"containers":3},"vision":true,"body":"character","module_errors":0,"tick":4109766,"seq":812}
```
`module_errors` — тот же счётчик, что в `hello` (агент видит его рост в течение игры); `body` — вид тела.
`near.enemies` — только в видимых чанках, радиус 32 клетки, до 20 ближайших; враги — сила
`enemy`, типы `unit`, `unit-spawner`, `turret`, `spider-unit`, `segmented-unit`. `job` берётся из
`jobs.active(helper)` ядра (ACTIONS.md).

## `map` (h?, `center?│near?:"player"`, `radius?=16` (≤ 32), `types?`, `names?`)
```json
{"bbox":{"x0":44,"y0":85,"x1":60,"y1":101},
 "axis":"x: 44...|50.......|60",
 "rows":["...ccc....D......", "..."],
 "legend":{".":"земля","~":"не пройти: lava","#":"утёс/скала","?":"не открыто","@":"помощник","P":"игрок",
           "D":"бур","F":"печь","A":"сборщик","B":"лента","I":"манипулятор","C":"сундук","E":"столб",
           "g":"призрак","c":"руда: calcite","w":"руда: tungsten-ore","k":"руда: coal"},
 "entities":[{"c":"D","name":"electric-mining-drill","pos":{"x":55.5,"y":90.5},"dir":0}],
 "truncated":false}
```
- Строки сверху вниз (север → юг), слева направо. `bbox` — координаты крайних клеток,
  `axis` — подпись столбцов (метка каждые 5 клеток), чтобы не считать символы.
- `map` **никогда** не отдаёт `not_charted`: неоткрытое рисуется `?`.
- Руды — свои строчные буквы, назначаются по первой свободной букве имени; легенда в ответе
  всегда полная для того, что нарисовано. Сущности — `bounding_box` закрашивается на всю площадь.
- В ответе ещё `surface`. Постоянные символы легенды сверх примера: `H` другой помощник,
  `L` труба, `T` дерево, `X` враг, `O` другая своя постройка.
- `entities` — до 100; по умолчанию только свои постройки (без лент, труб и столбов — их много),
  призраки и видимые враги; нейтральное (деревья, камни, руда) — только при явном `types?`/`names?`.
  Поля: `c, name, pos, dir, unit` (unit_number), у призрака `ghost:true` и `name` = имя внутренней
  сущности. `dir` — `defines.direction` 2.0: **16 направлений**, север 0, восток 4, юг 8, запад 12.
  Враги — только в видимых чанках.
- **Жидкости и преграды (все планеты).** `~` — плитка, по которой персонаж **не может пройти**
  (маска столкновений плитки пересекается с маской персонажа: глубокая вода, лава, мазутный и
  аммиачный океан и т.п.); `,` — мелкая жидкость: пройти можно, строить без подложки нельзя (в маске
  плитки есть `water_tile` или `lava_tile`, но персонаж проходит). Подпись в легенде называет плитки,
  которые реально нарисованы: `"~":"не пройти: lava"`, `",":"мелко: oil-ocean-shallow"`. Отдельное
  поле `liquids:{[tile_name]=клеток}` — сколько каких.
- Как считать (2.0): тайлы — одним `surface.find_tiles_filtered{area}`, проходимость — по
  `tile.prototype.collision_mask` и маске прототипа `character`; `#` — `cliff` и
  `simple-entity` с `prototype.count_as_rock_for_filtered_deconstruction`; `?` — по
  `force.is_chunk_charted(surface, chunk)`; сущности — `find_entities_filtered{area,
  force={own, "neutral", "enemy"}}`.
- Образец рисования — forge `experiments/2026-09-26-sand/asciimap.py` (читает экспорт, не API —
  брать только идею).

## `resources` (h?, `center?│near?`, `radius ≤ 128`, `name?`)
```json
{"patches":[{"name":"calcite","center":{"x":120,"y":40},"area":{"left_top":{"x":100,"y":28},"right_bottom":{"x":141,"y":55}},
  "tiles":612,"amount":3400000,"dist":70.2}],"truncated":false}
```
Пятна — кластеризация ресурсов по имени и соседству (8-связность), только открытые чанки,
не больше 20 пятен (ближайшие). `dist` — до центра пятна; пятна обрезаются кругом поиска: у такого
пятна `clipped:true`, а `tiles` и `amount` — только видимая в круге часть (нижняя оценка).
Без `name` мелкие источники (гейзеры и т.п.) могут занять все 20 мест — искать руду с `name`.
Неизвестное или не-ресурсное `name` → `bad_args`. Радиус 128 — дорогой режим (256×256 клеток,
десятки тысяч сущностей): агенту начинать с 32–64.

## `stock` (h?, `center?│near?`, `radius?=64 (≤128)`, `items?` — массив имён или `{name:count}`, `limit?=50 (≤200)`)
```json
{"containers":[{"unit":123,"name":"steel-chest","pos":{"x":10.5,"y":4.5},"dist":12.0,"items":{"iron-plate":800}}],
 "total":{"iron-plate":800},"hidden":2,"truncated":false}
```
Склады = контейнеры и логистические сундуки своей силы. Содержимое — только в видимых
чанках; невидимые считаются в `hidden`. Машины не считаются. Пустые (или без нужных `items`)
сундуки в `containers` не попадают; `truncated` — про список, `total` и `hidden` — по всем сундукам.

## `ghosts` (h?, `area?│radius?=64`, `center?│near?`)
```json
{"count":24,"by_name":{"electric-mining-drill":16,"transport-belt":120},
 "need":{"electric-mining-drill":16,"transport-belt":120},
 "have":{"helper":{"transport-belt":40},"stock":{"electric-mining-drill":30,"transport-belt":500}},
 "missing":{},"blocked":[{"name":"transport-belt","pos":{"x":3.5,"y":7.5}}],"area":{...}}
```
`blocked` — призраки, у которых `ghost_revive`-проверка = false (PROTOCOL §6.5), список до 50;
`blocked_total` — сколько всего. При > 1000 призраков проверяются не все: `blocked_partial:true`,
`blocked_total` — нижняя оценка. `need` включает `item_requests` призрака (модули) и предметы для
призраков плиток (`tile-ghost`); `tiles:int` — сколько призраков плиток, в `count`/`by_name` они не входят. `have.stock` — по складам в радиусе 64 от центра (видимые).

## `rates` (поток L; `top` ≤ 100, `items` ≤ 100; h?, `scope`, `area?`, `surface?`, `period`, `items?`, `top?=20`)
- `scope:"surface"` (по умолчанию поверхность помощника; в 2.0 статистика только по поверхности):
  `stats = force.get_item_production_statistics(surface)` (и `get_fluid_production_statistics`);
  made = `stats.get_flow_count{name, category="input", precision_index=<период>, count=true}`,
  used — то же с `"output"` (в API 2.0 `input` — произведено, левая колонка окна статистики;
  `output` — потреблено); имена — из `stats.input_counts`/`output_counts`.
  `period`: `1m` → `defines.flow_precision_index.one_minute`, `10m` → `ten_minutes`,
  `1h` → `one_hour`. Значения — **сумма за период** (не в минуту). Вернуть `top` по обороту
  (общий для предметов и жидкостей) или только `items`.
```json
{"scope":"surface","surface":"vulcanus","period":"1m",
 "items":{"iron-plate":{"made":1200,"used":950}},"fluids":{"water":{"made":36000,"used":35000}},"truncated":true}
```
- `scope:"area"` — **номинальная** оценка по машинам в `area` (`nominal:true`, машина может
  простаивать), **в минуту**:
  - циклов/мин = `crafting_speed / recipe.energy × 60` (`crafting_speed` в 2.0 уже с модулями и
    маяками); `in` = ингредиенты × циклы (**без** продуктивности); `out` = Σ (ожидаемое количество с
    `probability`, `amount_min/max`, `extra_count_fraction` + часть сверх `ignored_by_productivity`
    × `productivity_bonus`) × циклы; бонус ограничен `maximum_productivity` рецепта;
  - буры: `mining_speed × (1 + speed_bonus) / mining_time × 60` по `mining_target`; жидкость
    `required_fluid` — `fluid_amount / 10` на цикл; бесконечные ресурсы × `amount / normal_resource_amount`;
  - печь без текущего рецепта — по `previous_recipe`.
  Ответ: `{"scope","surface","area","per":"1m","machines":[{"name","recipe","count","in":{...},"out":{...}}],
  "net":{...},"nominal":true,"hidden":N,"idle":N,"truncated":bool}` — `hidden` машины в невидимых
  чанках (живые данные — только видимые), `idle` — без рецепта/цели или не-`normal` качества,
  `machines` до 100 групп. Сторона `area` ≤ 128.
- Машины `scope:"area"`: `assembling-machine`, `furnace`, `rocket-silo`, `mining-drill`; предел
  продуктивности — `maximum_productivity` рецепта (по умолчанию 3, т.е. +300 %).
- Без помощника поверхность/сила — хозяина (PROTOCOL §4 «h? без помощника»; хозяин офлайн и нет
  `surface` → `no_player`); явный `surface` сильнее. Ошибки: `bad_args`, `limit`, `not_found`
  (нет поверхности), `no_player`, `internal` (сбой `get_flow_count` — не пустой ответ).

## `find` (h?, `item`, `kinds?`, `surface?`, `limit?=20 (≤50)`) — поиск по всей базе
«Где у нас делают/тратят/хранят X» по всей поверхности, а не в области (образец — мод Factory Search,
MIT, автор Xorimuth: у него тоже обычный `find_entities_filtered` и разбор рецептов; программного
входа с данными у мода нет — `remote` только открывает окно игроку, поэтому поиск свой).
- `item` — имя предмета или жидкости; `kinds` — подмножество `["producers","consumers","storage",
  "entities"]` (по умолчанию первые три): кто производит (рецепт машины, буры по руде), кто потребляет,
  где лежит (сундуки, цистерны), сами постройки с таким именем.
- Только сущности силы помощника в открытых чанках; `storage` — только видимое (PROTOCOL §6.7),
  остальное `storage` считается как `hidden:int`.
- Ответ — **группы** (постройки ближе 32 клеток друг к другу — одна группа), ближайшие к помощнику
  (или хозяину) первыми: `{item, groups:[{kind, pos, dist, count, names:{[name]=n}, recipe?, amount?}],
  total:{producers,consumers,storage,entities}, surface, truncated?, hidden?}`; в группе при длинном
  списке имён — `names_more:int`. `total` — только по запрошенным `kinds`. `pos` — центр группы:
  годится как `center` для `map`/`rates`/`ghosts`/`collect`; как цель `walk` — только с `radius` ≥ 3
  (центр может оказаться внутри постройки).
- Кто есть кто: `producers` — машины с рецептом, дающим `item`, и буры, чья руда его даёт;
  `consumers` — машины с рецептом, где `item` — ингредиент; `storage` — сундуки и цистерны, где он
  лежит; `entities` — постройки с именем `item` (годится и имя постройки, не только предмета).
  Группировка приближённая (сетка, соседние постройки на 32–45 клеток могут попасть в одну группу).
- Лимит — по работе, а не по размеру карты: найдено больше 20000 сущностей → `limit` (сузить `kinds`).
  Числа чанков поверхности лимит не касается: открытость проверяется у найденных сущностей.

## `access` (h?, `area` │ `center?│near?` + `radius?=32 (≤64)`) — суша и выходы с участка
Отвечает на вопрос «можно ли сюда дойти и подвести ленту, и с какой стороны». Нужна там, где
участок окружён жидкостью или утёсами (лавовые озёра Вулкануса, острова), особенно пока нет
фундамента и отсыпки.
```json
{"area":{...},"land":812,"liquid":460,"liquids":{"lava":460},"enclosed":false,
 "exits":[{"side":"west","pos":{"x":96,"y":41},"width":3,"neck":"narrow"},
          {"side":"south","pos":{"x":118,"y":70},"width":14,"neck":"wide"}],
 "best":"south","reachable":true,"warnings":["narrow_access:west"]}
```
- Рамка — `area`, расширенная на 8 клеток. `land` / `liquid` — клеток суши и непроходимого внутри
  `area`; `liquids` — какие плитки.
- `exits` — участки рамки, где суша, связанная с сушей `area`, выходит наружу: сторона, середина,
  ширина по рамке и `neck` — самое узкое место по дороге от участка до этого выхода:
  `"narrow"` (1–2 клетки), `"medium"` (3–4), `"wide"` (≥ 5). Считается заливкой проходимых клеток с
  «усадкой» маски на 1 и 2 клетки (утёсы, камни и постройки — преграды, деревья — нет). До 8 выходов,
  широкие первыми; `best` — сторона самого широкого.
- `enclosed:true` — выходов нет (остров): пешком не дойти, ленту не вывести.
- `reachable` — есть ли путь от помощника (или хозяина) до суши участка по той же заливке в пределах
  рамки; помощник вне рамки → поле опущено (ответ даёт `walk`/`approach`).
- `warnings`: `narrow_access[:сторона]` — все выходы или лучший — `narrow`; `enclosed`; `not_charted:N` —
  столько клеток рамки не открыто (считаются преградой).
- Только открытые чанки; сторона `area` ≤ 128. Владелец — поток G (`scripts/perception/access.lua`);
  расчёт вынесен в функцию, которую зовёт и `plan_mining` (поток M) для своих предупреждений.

## `recipes` (h, `filter?`)
Перебор `force.recipes`: `enabled`, не `hidden`, категория ∈
`prototypes.entity["character"].crafting_categories`; значение —
`entity.get_craftable_count(name)`, нули не выводить; `filter` — подстрока имени (`""` — без фильтра).
`{"craftable":{"iron-gear-wheel":20,"pipe":40}}`.

## `vision` (h, `on`) — обзор помощника
Раз в 60 тиков для каждого живого помощника с `on`: чанки в радиусе 2 чанков от тела, которые
сгенерированы (`surface.is_chunk_generated`) и либо не открыты, либо открывались ≥ 10 с назад
(`storage.vision.charted[key]`); не больше 8 чанков за итерацию; `force.chart(surface, area)`
по границам чанков (лимит 8 — на каждого помощника). Хранение: `storage.vision = {on={[helper]=
{on, unit}}, charted={["<surface_index>:<cx>:<cy>"]=tick}}`. Нет записи — значит `on=true`
(ядро при `helper_spawn` ничего не пишет); запись с другим `unit_number` (новое тело после spawn
или возрождения) считается устаревшей → обзор снова включён. Мёртвый или удалённый помощник
(`storage.helpers[id].state ~= "alive"`) обзор не ведёт.
