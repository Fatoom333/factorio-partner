# Стенд живых тестов на ПК (поток E)

Контракт — [docs/TESTING.md §3](../../docs/TESTING.md). Запуск на ноутбуке, из PowerShell (не Git Bash):

```powershell
powershell -File tools/pc/run-live.ps1 -Slot 1 -Scenario e_rcon_maxlen
powershell -File tools/pc/run-live.ps1 -Slot 1 -Scenario e_chart -Keep      # папку слота не удалять
powershell -File tools/pc/run-live.ps1 -Slot 2 -Scenario move_walk -Mods factorio-partner
```

Итог — `%TEMP%\fp-live\<N>-<время>\results-<N>.json` (+ `live-<N>.log`, `factorio-<N>.log`).
Код выхода: 0 — сценарий ok, 1 — не ok, 2 — сбой стенда.

| Файл | Что делает |
|---|---|
| `run-live.ps1` | ноутбук: сборка → scp → развёртывание → сценарий → `/quit` → забрать итоги → уборка |
| `remote/stand.ps1` | ПК: `deploy` / `run` / `stop` в `D:\Temp\fp-live-<N>` |
| `live_client.py` | единственная точка отправки: только конверт → `/partner <JSON>`, отдельно `quit()`; RCON только `127.0.0.1` |
| `pack.py` | zip мода (`<name>_<version>/…`) и пакет стенда со `stand.json` |
| `scenarios/<имя>.py` | `run(client) -> {"ok": bool, ...}`; `MODS = [...]` — какие наши моды включить (по умолчанию `factorio-partner`) |

Слот N: папка `D:\Temp\fp-live-<N>`, RCON `127.0.0.1:27100+N`, игра `127.0.0.1:34200+N`.
Координатор — слот 0, потоки — 1..9. Пароль RCON генерируется на ПК в `<слот>\rcon.pw`
(файл создаётся пустым, права — только владельцу, потом пишется пароль), в git и `results` не попадает.

**Журналы.** Factorio пишет свои аргументы, включая пароль RCON, в `factorio-current.log`
(строка `Program arguments`). Поэтому `stand.ps1` выносит журнал только через `Copy-RedactedLog`
(пароль → `<private>`), хвост при сбое печатает тоже вычищенным, а при `stop` перезаписывает
вычищенными и сами журналы в слоте (на случай `-Keep`). Не заменяйте это на `Copy-Item`/`Get-Content` —
тест `tests/test_stand_logs.py` это ловит.

**Известное ограничение.** У Factorio нет способа передать пароль RCON файлом, поэтому, пока сервер
работает, пароль виден в командной строке `factorio.exe` любому локальному процессу пользователя
(`Get-CimInstance Win32_Process`). Смягчение: пароль одноразовый (новый на каждый запуск), RCON слушает
только `127.0.0.1`, сервер живёт минуты и работает на копии сейва.

**Сейв.** По умолчанию — `Vulkan-Start-test.zip` (копия рабочего сейва игрока, `DEFAULTS` в `pack.py` и `-Save` в `run-live.ps1`); рабочий `Vulkan-Start.zip` стенд не берёт. Сервер работает на копии `data\saves\fp-live.zip` в папке слота и на `/quit` её
пересохраняет. Это должна быть именно копия (`Copy-Item`), а не жёсткая ссылка: со ссылкой
пересохранение испортило бы сейв игрока. (Моды — жёсткие ссылки: сервер их только читает.)

**Пути ПК.** По умолчанию — в `DEFAULTS` в `pack.py`. Если игра или Python на ПК переехали, создайте
`tools/pc/pc.local.json` (в git не идёт) с нужными ключами из `factorio_exe`, `factorio_data`,
`pc_python`, `save`; ключи командной строки `pack.py` сильнее файла.

**Ответы RCON.** `live_client.py` собирает ответ из одного RCON-пакета: Factorio 2.0.77 отдаёт
300 КБ одним пакетом (замер 06.10). Сценарий `e_rcon_maxlen` проверяет это заново (`e_big`, ответ
≈200 КБ, поле `big_reply`); пакеты больше 1 МБ клиент не читает.

Сценарию доступно: `client.call(op, args, helper)` → ответ-конверт (dict), `client.call_ok(...)` → `data`
или исключение, `client.poll(fn, timeout, interval)`, `client.sleep(s)`, `client.time_left()`.

Сценарий `e_chart` проверяет обзор на **силе игрока** и далёком сгенерированном неоткрытом чанке.
Операция мода `e_chart` имеет режимы `find` / `chart` / `check`; тело и тестовая сила не создаются.
Для силы из `create_force` обзор без игроков не работает (замер 08.10). Успех: чанк открылся и открыто не меньше 21 из 25 чанков окна 5x5 (радиус 64 даёт «круг» без углов).

Мод `partner-test` регистрирует свой тестовый `/partner` (операции `hello`, `e_*`) только когда
`factorio-partner` выключен. Сценарии `e_*` требуют его (`MODS = ["partner-test"]`).

Тесты стенда (без ПК): `python -m pytest tools/pc/tests -q` (нужны `pytest`, для тестов Lua — `lupa`).
