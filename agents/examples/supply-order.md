# Пример: «поставь ещё литейных»

Большое поручение в общих словах: хозяин не говорит, из чего делать и где что лежит. Разбор по шагам —
что видит агент `partner`, что вызывает и что говорит. Числа, координаты и имена выдуманы; `helper` и
`key` в вызовах опущены. Блоки `call` проверяет `agents/lint.py`: разведка начинается с
`partner_supply`, а не с поиска по кускам, дальше идут план хозяину и работа — `collect` → `extract` →
`craft` → `insert` → `place`.

Начало смены (`partner_brief`, `partner_state`, рефлексы, «я на месте») — как в
[mining-order.md](mining-order.md), здесь опущено.

## 1. Понять

```json
{"kind":"player_said","data":{"player":"Owner","owner":true,"text":"поставь ещё две литейные вот тут [gps=-20,34,vulcanus]",
 "gps":[{"pos":{"x":-20,"y":34},"surface":"vulcanus"}]}}
```

`owner:true` — приказ. Что нужно: две литейные, место — точка из `gps`. Из чего их делать и где это
взять, хозяин не сказал и не должен.

## 2. Спросить игру: что из чего и где это взять

Один вызов вместо поиска по кускам:

```call
partner_supply {"item":"foundry","count":2}
```

Ответ (сокращён до главного):

```json
{"item":"foundry","count":2,"surface":"vulcanus","nodes":9,"hidden":3,
 "summary":{"short":[{"name":"foundry","n":2},{"name":"tungsten-carbide","n":100},{"name":"steel-plate","n":100},
                     {"name":"electronic-circuit","n":35},{"name":"refined-concrete","n":40},{"name":"lubricant","n":40},
                     {"name":"iron-plate","n":35},{"name":"copper-cable","n":105}],
            "raw":[]},
 "tree":{"name":"foundry","kind":"item","need":2,"have":0,"short":2,
  "recipe":{"name":"foundry","hand":false,"category":"metallurgy-or-assembling","yield":1,"crafts":2,"time":20,
   "makers":{"count":6,"pos":{"x":40,"y":12},"dist":38,"names":{"assembling-machine-3":6}},
   "ingredients":[
    {"name":"tungsten-carbide","kind":"item","need":100,"have":0,"short":100,"note":"depth",
     "stored":{"total":400,"pos":{"x":22,"y":-8},"dist":31,"n":400}},
    {"name":"steel-plate","kind":"item","need":100,"have":0,"short":100,"note":"depth",
     "producers":{"count":4,"pos":{"x":-14,"y":30},"dist":9,"names":{"foundry":4},"recipe":"casting-steel","out":180}},
    {"name":"electronic-circuit","kind":"item","need":60,"have":25,"short":35,
     "recipe":{"name":"electronic-circuit","hand":true,"category":"electronics","yield":1,"crafts":35,"time":210,
      "makers":{"count":6,"pos":{"x":40,"y":12},"dist":38,"names":{"assembling-machine-3":6}},
      "ingredients":[
       {"name":"iron-plate","kind":"item","need":35,"have":0,"short":35,"note":"depth",
        "stored":{"total":2400,"pos":{"x":22,"y":-8},"dist":31,"n":2400}},
       {"name":"copper-cable","kind":"item","need":105,"have":0,"short":105,"note":"depth",
        "stored":{"total":600,"pos":{"x":22,"y":-8},"dist":31,"n":600}}]}},
    {"name":"refined-concrete","kind":"item","need":40,"have":0,"short":40,"note":"depth",
     "stored":{"total":900,"pos":{"x":22,"y":-8},"dist":31,"n":900}},
    {"name":"lubricant","kind":"fluid","need":40,"have":0,"short":40,"note":"depth",
     "stored":{"total":12000,"pos":{"x":44,"y":20},"dist":44,"n":12000}}]}},
 "warnings":[]}
```

Как агент это читает — по узлам, источник берётся первый подходящий:

| узел | что в ответе | что делать |
|---|---|---|
| `tungsten-carbide`, `refined-concrete` | `stored` у (22, −8) | забрать со склада (`collect`) |
| `steel-plate` | `stored` нет; `producers` — 4 литейные у (−14, 30), `out: 180` | забрать из выхода (`extract`) |
| `electronic-circuit` | `stored` и `producers` нет; `makers` есть, `recipe.hand: true` | сказать хозяину про `makers`; не ждать — сделать 35 штук руками (`craft`), сырьё лежит на складе |
| `iron-plate`, `copper-cable` | `stored` у (22, −8) | забрать вместе с остальным |
| `lubricant` | жидкость, `stored` — цистерна у (44, 20) | в карманы не взять: нужна машина с подведённой трубой |
| `foundry` | `recipe.hand: false` (среди ингредиентов жидкость), `producers` нет, `makers` — 6 сборщиков у (40, 12) | рецепт ставит хозяин: спросить, можно ли занять один |

`hidden: 3` — три сундука или машины вне обзора; всё нужное и так найдено, подходить ближе незачем.
`warnings` пуст — ничего неоткрытого и ничего «без источника». Будь там `not_researched:foundry` —
на этом всё бы кончилось одной строкой хозяину.

## 3. План хозяину и одна настоящая развилка

Очевидное агент делает сам; спрашивает только про чужую машину под другой рецепт:

```call
partner_say {"text":"2 литейные: карбид, бетон и медь — со склада [gps=22,-8,vulcanus], сталь — из выхода литейных, платы докручу руками. Сама литейная требует смазку: занять сборщик у [gps=40,12,vulcanus]?"}
partner_act {"do":"collect","args":{"items":{"tungsten-carbide":100,"refined-concrete":40,"iron-plate":35,"copper-cable":105},"center":{"x":22,"y":-8},"radius":16}}
partner_wait {"timeout":55}
```

Ответа агент не ждёт сложа руки: сбор со склада от решения хозяина не зависит. `job_done` → `collected`
совпадает с заявкой, `missing: {}`.

## 4. Сталь — из выхода машин

`producers.pos` — центр группы, а не машина. Конкретную литейную агент берёт с карты:

```call
partner_map {"center":{"x":-14,"y":30},"radius":8,"names":["foundry"]}
partner_act {"do":"extract","args":{"target":{"name":"foundry","pos":{"x":-16.5,"y":28.5}},"items":{"steel-plate":100}}}
partner_wait {"timeout":55}
```

`job_done` → `extracted: {"steel-plate": 52}` — в одной машине столько не было. Остаток — из соседней:

```call
partner_act {"do":"extract","args":{"target":{"name":"foundry","pos":{"x":-11.5,"y":28.5}},"items":{"steel-plate":48}}}
partner_wait {"timeout":55}
```

Руками сталь агент не делает и печь себе не ставит: машины на базе её уже делают.

## 5. Платы — руками

У плат нет `producers` (на этой планете их не делают, запас привезён), а `recipe.hand` — `true`:

```call
partner_act {"do":"craft","args":{"recipe":"electronic-circuit","count":35}}
partner_wait {"timeout":55}
```

`job_done` → `crafted: {"electronic-circuit": 35}`; вместе с 25 из карманов — нужные 60.

## 6. Ответ хозяина и сборка

Тем временем пришло:

```json
{"kind":"player_said","data":{"player":"Owner","owner":true,"text":"бери крайний, рецепт поставил, смазка подведена"}}
```

Агент не гадает, какой сборщик «крайний», а спрашивает игру ещё раз — теперь у корня появился `producers`:

```call
partner_supply {"item":"foundry","count":2,"depth":1}
partner_map {"center":{"x":45,"y":12},"radius":4,"names":["assembling-machine-3"]}
```

→ `producers: {"count":1,"pos":{"x":45.5,"y":12.5},"dist":43,"names":{"assembling-machine-3":1},"recipe":"foundry","out":0}`.
`out: 0` — машина есть, но пустая: донести сырьё и подождать.

```call
partner_act {"do":"insert","args":{"target":{"name":"assembling-machine-3","pos":{"x":45.5,"y":12.5}},"items":{"tungsten-carbide":100,"steel-plate":100,"electronic-circuit":60,"refined-concrete":40}}}
partner_act {"do":"wait","args":{"seconds":30}}
partner_act {"do":"extract","args":{"target":{"name":"assembling-machine-3","pos":{"x":45.5,"y":12.5}},"items":{"foundry":2}}}
partner_wait {"timeout":55}
```

`job_done` последней задачи → `extracted: {"foundry": 2}`. Пришло бы меньше — ещё один `wait` и снова
`extract`, а не крафт руками.

## 7. Поставить и отчитаться

Место — точка из пинга; перед постройкой агент смотрит, свободно ли там:

```call
partner_map {"center":{"x":-20,"y":34},"radius":8}
partner_act {"do":"place","args":{"item":"foundry","pos":{"x":-20.5,"y":34.5},"direction":0}}
partner_act {"do":"place","args":{"item":"foundry","pos":{"x":-14.5,"y":34.5},"direction":0}}
partner_wait {"timeout":55}
partner_say {"text":"Две литейные стоят у [gps=-20,34,vulcanus]. Рецепт и трубы — за тобой: скажи, что в них лить."}
partner_wait {"timeout":55}
```

## Что было бы иначе

| в ответе `partner_supply` | что делает агент |
|---|---|
| `summary.short` пуст | всё уже в карманах — сразу идти и ставить |
| у узла `note:"depth"`, а источников (`stored`, `producers`) нет | `partner_supply` для этого узла отдельно: `item` — его имя, `count` — его `short` |
| `truncated:true` или `response too large` | тот же вызов с меньшим `depth`, потом отдельно по нераскрытым узлам |
| `resource` у сырья, `drills: 0` | буров на пятне нет — обычное поручение «добыча» ([mining-order.md](mining-order.md)), сначала сказав хозяину |
| `resource` с `drills > 0` | добыча уже идёт: искать, куда она везёт (`partner_find` по руде), и брать там |
| `warnings: ["not_researched:…"]` | сделать нельзя — одной строкой хозяину, какой рецепт не открыт |
| `warnings: ["no_source:…"]` | нет ни запаса, ни машины, ни рецепта, ни пятна рядом — одной строкой хозяину, чего нет |
| `warnings: ["other_surface"]` | на этой планете ничего нужного нет — сказать хозяину, сам на другую планету не попадёшь |
| `hidden` большой, а нужного не видно | подойти к базе ближе и спросить снова: сундуки и выходы машин видны только рядом |
