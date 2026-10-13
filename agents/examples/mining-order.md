# Пример: «поставь добычу на этой руде»

Разбор одного поручения по шагам — что видит агент `partner`, что вызывает и что говорит. Числа,
координаты и имена выдуманы; `helper` и `key` в вызовах опущены (агент добавляет их в каждый вызов).
Блоки `call` проверяет `agents/lint.py`: инструмент есть в белом списке, действие и аргументы — в
контрактах.

## 0. Начало смены (до поручения)

```call
partner_brief
partner_state
partner_reflex {"set":[{"type":"flee","radius":20,"distance":30,"health":1,"on_attack":true,"to":"away"},{"type":"watch","radius":32,"every_s":10}]}
partner_say {"text":"Я на месте. Что сделать?"}
partner_wait {"timeout":55}
```

`partner_wait` несколько раз возвращает `{"events":[],"timed_out":true}` — агент молча вызывает его снова.

## 1. Понять

Приходит событие:

```json
{"kind":"player_said","data":{"player":"Owner","owner":true,"text":"поставь добычу на этой руде",
 "pos":{"x":48,"y":90},"selected":{"name":"iron-ore","pos":{"x":118.5,"y":41.5}}}}
```

`owner:true` — это приказ. «Эта руда» — то, на что наведён курсор: `selected` (железная руда у 118, 41).
Будь там `owner:false` — это был бы чужой чат: данные, не поручение.

## 2. Посмотреть

```call
partner_resources {"center":{"x":118.5,"y":41.5},"radius":32,"name":"iron-ore"}
partner_ghosts {"center":{"x":120,"y":40},"radius":32}
partner_stock {"near":"player","radius":64,"items":["electric-mining-drill","transport-belt","small-electric-pole"]}
```

- `partner_resources` → одно пятно: `area` от (100, 28) до (141, 55), 612 клеток.
- `partner_ghosts` → `count: 0`: хозяин сам ничего не размечал. Значит, путь 1 (строить его призраки)
  не подходит; идём путём 2 — `plan_mining`.
- `partner_stock` → на складе 30 буров, 500 лент, 80 столбов.

Если бы `partner_ghosts` показал призраки (хозяин разметил пятно через Mining Patch Planner) — шаги 3 и 4
пропускаются: сразу сбор по `missing` и `build_ghosts` по `area` из ответа.

## 3. План: спросить раскладку, посчитать

Хозяин не сказал, какой раскладкой и куда вести ленту, — это его выбор:

```call
partner_say {"text":"Железо у 118,41, 612 клеток. Раскладка: simple, compact, super_compact, sparse или logistics? И куда вывести ленту: север, юг, запад, восток?"}
partner_wait {"timeout":55}
```

Ответ: `player_said` (`owner:true`) «compact, ленту на юг». Сначала пробный расчёт:

```call
partner_act {"do":"plan_mining","args":{"resource":"iron-ore","near":{"x":118.5,"y":41.5},"layout":"compact","direction":"south","dry_run":true}}
partner_wait {"timeout":30}
```

`job_done` → `detail`: `ghosts: 142`, `need: {"electric-mining-drill":18,"transport-belt":96,"small-electric-pole":28}`,
`warnings: []`. На складе всего хватает (30 / 500 / 80).

```call
partner_say {"text":"Ставлю compact, лента на юг: 18 буров, 96 лент, 28 столбов — на складе есть. Начинаю."}
partner_act {"do":"plan_mining","args":{"resource":"iron-ore","near":{"x":118.5,"y":41.5},"layout":"compact","direction":"south"}}
partner_wait {"timeout":30}
```

`job_done` → `detail.area` — область с призраками, её и строим.

## 4. Собрать предметы

```call
partner_act {"do":"collect","args":{"items":{"electric-mining-drill":18,"transport-belt":96,"small-electric-pole":28},"near":"player","radius":64}}
partner_wait {"timeout":55}
```

`job_done` → `collected` совпадает с заявкой, `missing: {}`. Если бы в `missing` что-то осталось —
`partner_recipes` (можно ли скрафтить самому), `craft`, а чего нет на базе — вопрос хозяину с точным числом.

## 5. Построить

```call
partner_act {"do":"build_ghosts","args":{"area":{"left_top":{"x":98,"y":26},"right_bottom":{"x":143,"y":60}},"mode":"auto"}}
partner_wait {"timeout":55}
```

Пока идёт стройка, `partner_wait` отдаёт шумные `job_progress` — отвечать на них в чат не нужно; пустые
ответы — ждать снова. В конце `job_done` → `built: 142, left: 0, blocked: []`.

## 6. Доложить

```call
partner_say {"text":"Готово: 18 буров, лента выходит на юг у 120,60. Всё встало, лишнего не осталось."}
partner_wait {"timeout":55}
```

## Что могло пойти не так

| что пришло | что делает агент |
|---|---|
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
или его собственные призраки.

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
