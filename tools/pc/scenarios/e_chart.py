"""Проверка: `force.chart` силой игрока открывает далёкий неоткрытый чанк на сервере без игроков
онлайн (поток E, TESTING.md §3, PROTOCOL §6.8). Живой замер 08.10: для силы игрока работает,
для силы из `create_force` — нет, поэтому проверяем именно силу игрока.

Ход:
1. `hello` — мод partner-test, игроков онлайн 0.
2. `e_chart{mode:find}` — ближайший сгенерированный, но не открытый чанк в 8..64 чанках от игрока 1.
3. Контроль: ждём BASELINE_S, чанк сам не открывается и тики идут.
4. `e_chart{mode:chart}` — force.chart вокруг центра чанка, как будет делать обзор помощника.
5. Ждём до CHART_TIMEOUT_S, пока чанк не станет открытым.
Мод тело не создаёт и в мире ничего не оставляет, уборка не нужна.
"""
from __future__ import annotations

MODS = ["partner-test"]

BASELINE_S = 5.0
CHART_TIMEOUT_S = 30.0
RADIUS = 64
# Живой замер 09.10: радиус 64 тайла открывает «круг» — 21 из 25 чанков окна 5x5 (без четырёх углов).
MIN_WINDOW_CHARTED = 21
POLL_S = 1.0


def run(client) -> dict:
    hello = client.call_ok("hello")
    mod = str(hello.get("mod", ""))
    if not mod.startswith("partner-test"):
        return {"ok": False, "error": {"kind": "setup", "text": f"нужен мод partner-test (-Mods partner-test), а ответил {mod!r}"}}
    online = hello.get("players_online", sum(1 for p in hello.get("players", []) if p.get("online")))
    result = {"mod": mod, "players_online": online}

    found = client.call_ok("e_chart", {"mode": "find"})
    chunk = found["chunk"]
    result["chunk"] = chunk
    result["dist"] = found.get("dist")
    result["force"] = found.get("force")

    before = client.call_ok("e_chart", {"mode": "check", "chunk": chunk})
    client.sleep(BASELINE_S)
    base = client.call_ok("e_chart", {"mode": "check", "chunk": chunk})
    result["baseline"] = {"charted": base["charted"], "ticks": base["tick"] - before["tick"]}
    result["ticks_advance"] = base["tick"] > before["tick"]

    start = client.call_ok("e_chart", {"mode": "chart", "chunk": chunk, "radius": RADIUS})

    def charted():
        st = client.call_ok("e_chart", {"mode": "check", "chunk": chunk})
        charted.last = st
        return bool(st["charted"])
    charted.last = start

    done = client.poll(charted, CHART_TIMEOUT_S, POLL_S)
    last = charted.last
    result["after"] = {"charted": bool(last["charted"]), "window_charted": last.get("window_charted"),
                       "window": last.get("window"), "ticks_to_chart": last["tick"] - start["tick"],
                       "players_online": last["players_online"]}
    result["ok"] = bool(
        done
        and result["ticks_advance"]
        and not before["charted"]
        and not base["charted"]
        and (last.get("window_charted") or 0) >= MIN_WINDOW_CHARTED
        and last["players_online"] == 0
    )
    if not result["ok"]:
        reasons = []
        if not result["ticks_advance"]:
            reasons.append("tick не растёт (auto_pause?)")
        if before["charted"] or base["charted"]:
            reasons.append("чанк открыт ещё до force.chart")
        if last["players_online"] != 0:
            reasons.append("на сервере есть игроки — проверка не про «без игроков»")
        if (last.get("window_charted") or 0) < MIN_WINDOW_CHARTED:
            reasons.append(f"окно открыто слабо: {last.get('window_charted')} из {last.get('window')}, нужно >= {MIN_WINDOW_CHARTED}")
        if not done:
            reasons.append(f"за {CHART_TIMEOUT_S:.0f} с чанк {chunk} не открылся")
        result["reasons"] = reasons
    return result
