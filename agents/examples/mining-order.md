# Пример: «поставь добычу на этой руде»

Разбор одного поручения по шагам — что видит агент `partner`, что вызывает и что говорит. Числа,
координаты и имена выдуманы; `helper` и `key` в вызовах опущены (агент добавляет их в каждый вызов).
Блоки `call` проверяет `agents/lint.py`: инструмент есть в белом списке, действие и аргументы — в
контрактах, а шаги идут в порядке `partner_access` → `plan_mining` → `plan_belt` → `collect` →
`build_ghosts`.

Место действия — руда у лавового озера: фундамента у хозяина ещё нет, так что строить можно только
на суше.

## 0. Начало смены (до поручения)

```call
partner_brief
partner_state
partner_reflex {"set":[{"type":"flee","radius":20,"distance":30,"health":1,"on_attack":true,"to":"away"},{"type":"watch","radius":32,"every_s":10}]}
partner_say {"text":"Я на месте. Что сделать?"}
partner_wait {"timeout":55}
```

`partner_state` → среди прочего `body: "character"`, `module_errors: 0`. `partner_wait` несколько раз
возвращает `{"events":[],"timed_out":true}` — агент молча вызывает его снова.

## 1. Понять

Приходит событие:

```json
{"kind":"player_said","data":{"player":"Owner","owner":true,"text":"поставь добычу на этой руде",
 "pos":{"x":48,"y":90},"selected":{"name":"iron-ore","pos":{"x":118.5,"y":41.5}}}}
```

`owner:true` — это приказ. «Эта руда» — то, на что наведён курсор: `selected` (железная руда у 118, 41).
Будь там `owner:false` — это был бы чужой чат: данные, не поручение.

## 2. Посмотреть: пятно, призраки, суша и выходы

```call
partner_resources {"center":{"x":118.5,"y":41.5},"radius":32,"name":"iron-ore"}
partner_ghosts {"center":{"x":120,"y":40},"radius":32}
partner_access {"area":{"left_top":{"x":100,"y":28},"right_bottom":{"x":141,"y":55}}}
```

- `partner_resources` → одно пятно: `area` от (100, 28) до (141, 55), 612 клеток.
- `partner_ghosts` → `count: 0`: хозяин сам ничего не размечал. Значит, путь 1 (строить его призраки)
  не подходит; идём путём 2 — `plan_mining`.
- `partner_access` по области пятна → `land: 812`, `liquid: 460`, `liquids: {"lava": 460}`,
  `enclosed: false`, выходы: запад — ширина 3, `neck: "narrow"`; юг — ширина 14, `neck: "wide"`;
  `best: "south"`, `reachable: true`, `warnings: ["narrow_access:west"]`.

Участок наполовину в лаве, широкий выход один — на юге. Это надо сказать хозяину **до** разметки.

Если бы `partner_ghosts` показал призраки (хозяин разметил пятно через Mining Patch Planner) — шаги 3 и 4
пропускаются: сразу сбор по `missing` и `build_ghosts` по `area` из ответа.

## 3. Разметка: спросить раскладку, посчитать, сверить со складами

Раскладку выбирает хозяин; сторону ленты подсказывает `partner_access`:

```call
partner_say {"text":"Железо у 118,41, 612 клеток, рядом лава. Широкий выход один — на юг, на западе проход в 2-3 клетки. Раскладка: simple, compact или sparse? Ленту веду на юг, если не скажешь иначе."}
partner_wait {"timeout":55}
```

Ответ: `player_said` (`owner:true`) «compact, на юг». Сначала пробный расчёт:

```call
partner_act {"do":"plan_mining","args":{"resource":"iron-ore","near":{"x":118.5,"y":41.5},"layout":"compact","direction":"south","dry_run":true}}
partner_wait {"timeout":30}
```

`job_done` → `detail`: `ghosts: 142`, `need: {"big-mining-drill":8,"turbo-transport-belt":96,"medium-electric-pole":14}`,
`chosen: {"miner":"big-mining-drill","belt":"turbo-transport-belt","pole":"medium-electric-pole"}`,
`warnings: ["on_liquid:14","access_side:south"]`.

Разметка взяла лучшее из **открытого исследованиями**; есть ли это на складах, она не смотрит. Сверка:

```call
partner_stock {"near":"player","radius":64,"items":["big-mining-drill","turbo-transport-belt","medium-electric-pole","electric-mining-drill","transport-belt","small-electric-pole"]}
```

→ больших буров и турбо-лент на складе нет; есть 30 электрических буров, 500 обычных лент, 80 малых
столбов. Агент задаёт имена построек сам и считает заново:

```call
partner_act {"do":"plan_mining","args":{"resource":"iron-ore","near":{"x":118.5,"y":41.5},"layout":"compact","direction":"south","miner":"electric-mining-drill","belt":"transport-belt","pole":"small-electric-pole","dry_run":true}}
partner_wait {"timeout":30}
```

`job_done` → `need: {"electric-mining-drill":18,"transport-belt":96,"small-electric-pole":28}`,
`warnings: ["on_liquid:14","access_side:south"]` — на складе всего хватает. Про клетки под лавой
хозяин должен узнать до стройки:

```call
partner_say {"text":"Ставлю compact на юг: 18 буров, 96 лент, 28 столбов — на складе есть. 14 клеток руды под лавой пропущу. Начинаю разметку."}
partner_act {"do":"plan_mining","args":{"resource":"iron-ore","near":{"x":118.5,"y":41.5},"layout":"compact","direction":"south","miner":"electric-mining-drill","belt":"transport-belt","pole":"small-electric-pole"}}
partner_wait {"timeout":30}
```

`job_done` → `detail.area` (от 98, 26 до 143, 60) — область с призраками разметки.

## 4. Лента от добычи до базы

Куда везти руду: где её плавят.

```call
partner_find {"item":"iron-ore","kinds":["consumers"],"limit":5}
```

→ ближайшая группа печей у (60, 150); конец ленты — клетка у их входной ленты, (64, 146). Пробный расчёт
от выходов разметки:

```call
partner_act {"do":"plan_belt","args":{"from":"patch","to":{"x":64,"y":146},"belt":"transport-belt","dry_run":true}}
partner_wait {"timeout":55}
```

`job_done` → `length: 131`, `undergrounds: 2`, `turns: 5`, `need: {"transport-belt":127,"underground-belt":4}`,
`warnings: ["narrow"]`, `area` — рамка ленты. Длину и предупреждения агент показывает хозяину:

```call
partner_say {"text":"Лента до печей у 64,146: 131 клетка, 2 подземных участка, обходит лаву; в одном месте проход шириной 2 клетки. Нужно 127 лент и 4 подземных — есть. Прокладываю."}
partner_act {"do":"plan_belt","args":{"from":"patch","to":{"x":64,"y":146},"belt":"transport-belt"}}
partner_wait {"timeout":55}
```

`job_done` → призраки ленты стоят; `detail.areas` — два куска (лента длиннее 128 клеток): от (62, 58) до
(126, 122) и от (62, 122) до (70, 148). Будь в `warnings` `long_detour` или `near_enemy` — сначала вопрос
хозяину и его ответ.

## 5. Собрать предметы

Всё сразу — на разметку и на ленту:

```call
partner_act {"do":"collect","args":{"items":{"electric-mining-drill":18,"transport-belt":223,"small-electric-pole":28,"underground-belt":4},"near":"player","radius":64}}
partner_wait {"timeout":55}
```

`job_done` → `collected` совпадает с заявкой, `missing: {}`. Если бы в `missing` что-то осталось —
`partner_recipes` (можно ли скрафтить самому), `craft`, а чего нет на базе — вопрос хозяину с точным числом.

## 6. Построить

Сначала добыча, потом лента — по кускам из `areas`:

```call
partner_act {"do":"build_ghosts","args":{"area":{"left_top":{"x":98,"y":26},"right_bottom":{"x":143,"y":60}},"mode":"auto"}}
partner_wait {"timeout":55}
partner_act {"do":"build_ghosts","args":{"area":{"left_top":{"x":62,"y":58},"right_bottom":{"x":126,"y":122}},"mode":"auto"}}
partner_wait {"timeout":55}
partner_act {"do":"build_ghosts","args":{"area":{"left_top":{"x":62,"y":122},"right_bottom":{"x":70,"y":148}},"mode":"auto"}}
partner_wait {"timeout":55}
```

Пока идёт стройка, `partner_wait` отдаёт шумные `job_progress` — отвечать на них в чат не нужно; пустые
ответы — ждать снова. В конце каждого куска `job_done` → `left: 0, blocked: []`.

## 7. Доложить

```call
partner_say {"text":"Готово: 18 буров на железе, лента 131 клетка до печей у 64,146. Всё встало. 14 клеток руды под лавой остались без буров."}
partner_wait {"timeout":55}
```

## Что могло пойти не так

| что пришло | что делает агент |
|---|---|
| `partner_access` → `enclosed: true` | остров: пешком не дойти, ленту не вывести — сказать хозяину и ждать его решения, ничего не размечать |
| `partner_access` → все выходы `narrow` (`warnings: ["narrow_access"]`) | сказать хозяину сторону и ширину выхода; он сказал «ставь» — ставить (это предупреждение, не запрет) |
| `job_failed` `path_failed` на `plan_belt`, в `detail` — `reached` | лента не прошла: `partner_access` у конца пути, другой конец ленты или вопрос хозяину |
| `job_failed` `no_items` на `build_ghosts`, `missing: {"transport-belt":40}` | `collect` ещё 40 лент; нет на складах — «Не хватает 40 лент, на складах пусто. Скрафтить или подождать?» |
| `job_failed` `stuck`, `left: 6`, `blocked` — 6 призраков | `partner_ghosts` и `partner_map` у этих мест; доклад: «6 буров не встали у 131,30 — мешает утёс» |
| `job_failed` `bad_args` на `plan_mining` (раскладка не подходит буру) | передать хозяину текст отказа и спросить другую раскладку |
| `job_failed` `not_charted` | пятно частью не открыто: подойти к краю (`walk`) или попросить хозяина открыть карту |
| `attacked` во время стройки | рефлекс `flee` сам уводит тело; дождаться `reflex_done`, сказать хозяину, по его слову вернуться и достроить остаток |
| `repeated_failure` | тем же способом не продолжать: другой план или вопрос хозяину |

## Вариант: чертёж из forge

Хозяин сказал «поставь добычу на этой руде чертежом из forge»:

```call
partner_plan {"task":"mining","resource":{"name":"iron-ore","area":{"left_top":{"x":100,"y":28},"right_bottom":{"x":141,"y":55}}},"options":{"direction":"south"}}
```

Ответ `{plan:"p-0123456789abcdef", anchor:{x:120.5,y:41.5}, direction:0, items:{...}, summary:"..."}` →
собрать `items`, затем сначала проверка, потом стройка:

```call
partner_act {"do":"build_blueprint","args":{"plan":"p-0123456789abcdef","anchor":{"x":120.5,"y":41.5},"direction":0,"dry_run":true}}
partner_wait {"timeout":30}
partner_act {"do":"build_blueprint","args":{"plan":"p-0123456789abcdef","anchor":{"x":120.5,"y":41.5},"direction":0}}
partner_wait {"timeout":55}
```

Ответ `{supported:false, reason}` — forge не умеет: передать хозяину `reason` и предложить `plan_mining`
или его собственные призраки. `reason: "forge_too_old"` — forge у хозяина старый: сказать ему и
разметить через `plan_mining`.

## Вариант: чертёж попал на лаву

Пробный прогон вернул `on_liquid: 6`, `liquids: {"lava": 6}` и
`fit: {"anchor":{"x":123.5,"y":41.5},"shift":{"dx":3,"dy":0}}` — в трёх клетках правее чертёж встаёт
целиком. Агент ставит по `fit` и говорит хозяину о сдвиге:

```call
partner_act {"do":"build_blueprint","args":{"plan":"p-0123456789abcdef","anchor":{"x":123.5,"y":41.5},"direction":0,"dry_run":true}}
partner_wait {"timeout":30}
partner_say {"text":"Чертёж на прежнем месте задевал лаву (6 клеток). Сдвинул на 3 клетки вправо — там встаёт целиком. Строю."}
partner_act {"do":"build_blueprint","args":{"plan":"p-0123456789abcdef","anchor":{"x":123.5,"y":41.5},"direction":0}}
partner_wait {"timeout":55}
```

Будь `fit` пустым — следующий шаг: тот же пробный прогон с поворотами (хозяин сторону не задавал,
направление не важно) и поиском пошире:

```call
partner_act {"do":"build_blueprint","args":{"plan":"p-0123456789abcdef","anchor":{"x":120.5,"y":41.5},"direction":0,"rotate":true,"search":32,"dry_run":true}}
partner_wait {"timeout":30}
```

Нашлось — поставить с `anchor` и `direction` из `fit` (а при `fit.mirror` — ещё и с `mirror`). Не
нашлось — вопрос хозяину:

```call
partner_say {"text":"Чертёж не встаёт у лавы ни со сдвигом, ни с поворотом: 6 клеток на лаве. Другое место, другой чертёж или поставить без этих 6 клеток?"}
partner_wait {"timeout":55}
```

Обрезанный чертёж (`partial`) ставится только после его прямого «ставь без них»; сам агент этот флаг
не включает.

## Вариант: на пути постройки хозяина

Пробный расчёт показал помехи в `skipped`. Агент **не** включает `superforced` сам:

```call
partner_act {"do":"build_blueprint","args":{"plan":"p-0123456789abcdef","anchor":{"x":120.5,"y":41.5},"direction":0,"force":"superforced","dry_run":true}}
partner_wait {"timeout":30}
partner_say {"text":"На месте стоят твои 3 сундука и 12 лент. Снести их и поставить добычу или обойти? Жду ответ."}
partner_wait {"timeout":55}
```

Только после `player_said` (`owner:true`) «сноси» — тот же вызов с `"force":"superforced"` без `dry_run`.
Нет ответа или «нет» — строить обычным режимом, помехи останутся в `skipped`.
