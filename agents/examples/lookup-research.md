# Пример: «сделай литейные», а рецепт не открыт

Справка как в Факториопедии (ревизия 3.8): помощник не знает игру наизусть и спрашивает её саму. Разбор
по шагам — что видит агент `partner`, что вызывает и что говорит. Числа и имена выдуманы; `helper` и
`key` в вызовах опущены. Блоки `call` проверяет `agents/lint.py`: сначала `partner_lookup`, потом строка
хозяину, действий нет — помощник сам ничего не изучает.

## 1. Поручение и первый ответ игры

```json
{"kind":"player_said","data":{"player":"Owner","owner":true,"text":"сделай пару литейных"}}
```

Как в [supply-order.md](supply-order.md), агент сначала спрашивает игру, что из чего и где взять:

```call
partner_supply {"item":"foundry","count":2}
```

→ корень `{"name":"foundry","need":2,"have":0,"short":2,"note":"not_researched"}`,
`warnings: ["not_researched:foundry"]`. Сделать нельзя — но «не открыто» хозяину мало: какая технология
и чего не хватает?

## 2. Какая технология открывает рецепт

```call
partner_lookup {"name":"foundry","kind":"recipe"}
```

Ответ (сокращён до главного):

```json
{"kind":"recipe","name":"foundry","enabled":false,"category":"crafting-with-fluid","hand":false,"time":10,
 "ingredients":[{"name":"tungsten-carbide","type":"item","amount":50},{"name":"steel-plate","type":"item","amount":50},
                {"name":"electronic-circuit","type":"item","amount":30},{"name":"refined-concrete","type":"item","amount":20},
                {"name":"lubricant","type":"fluid","amount":20}],
 "products":[{"name":"foundry","type":"item","amount":1}],
 "machines":["assembling-machine-2","assembling-machine-3"],"machines_total":2,
 "unlocked_by":["foundry"]}
```

`unlocked_by` — технология `foundry`. Чего для неё не хватает:

```call
partner_lookup {"name":"foundry","kind":"technology"}
```

```json
{"kind":"technology","name":"foundry","researched":false,"enabled":true,"available":false,
 "prerequisites":[{"name":"tungsten-carbide","researched":false}],
 "missing":["calcite-processing","tungsten-carbide"],
 "unlocks":["foundry","molten-iron","molten-copper","casting-iron"],
 "other_effects":[],
 "cost":{"count":200,"ingredients":[{"name":"automation-science-pack","amount":1},
         {"name":"logistic-science-pack","amount":1},{"name":"chemical-science-pack","amount":1}],"time":30}}
```

`missing` — в порядке изучения: сначала `calcite-processing`, потом `tungsten-carbide`, потом сама
`foundry`. Первую стоит проверить: вдруг она изучается действием, а не колбами.

```call
partner_lookup {"name":"calcite-processing","kind":"technology"}
```

→ `"trigger":{"type":"mine-entity","entity":"calcite"}`, `cost` нет — изучится сама, когда кто-то
добудет кальцит.

## 3. Сказать хозяину — коротко

```call
partner_say {"text":"Литейная не открыта: нужна технология foundry (200 × красные, зелёные, синие колбы). До неё: calcite-processing (добыть кальцит) и tungsten-carbide."}
partner_wait {"timeout":55}
```

Сам агент ничего не изучает и колбы в лаборатории не несёт: что исследовать, решает хозяин. Скажет
«добудь кальцит» — это уже обычное поручение (добыча, раздел 7 промпта).

## Что было бы иначе

| в ответе `partner_lookup` | что делает агент |
|---|---|
| `not_found`, в тексте `suggest: …` | имя не то: берёт подходящее из подсказок и спрашивает снова |
| у технологии `available: true` | всё для неё изучено — хозяину: «можно ставить в исследование, стоит …» |
| `missing` длинный (до 30) | хозяину — только первые 2–3 по порядку и сколько всего |
| `trigger` вместо `cost` | изучается действием (добыть, скрафтить, построить) — так и сказать |
| у предмета `researched_any: true`, но рецепт в `made_by` выключен | есть другой открытый рецепт — `partner_supply` по предмету |
