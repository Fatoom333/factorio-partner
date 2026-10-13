"""Сценарии через НАСТОЯЩИЙ пакет сервера (server_client.py + server/factorio_partner): e2e_mcp и
e2e_forge против модели мода. Core, bridge и rcon — настоящие, мод — e2e_world.World за фейковым RCON.

Нужны Python ≥ 3.11 и зависимости сервера (`factorio-rcon-py[async]`); без них модуль пропускается —
остальные тесты стенда работают на одной стандартной библиотеке.
"""
from __future__ import annotations

import json
import os
import sys
import types

import pytest

if sys.version_info < (3, 11):
    pytest.skip("пакету сервера нужен Python 3.11+", allow_module_level=True)
pytest.importorskip("factorio_rcon", reason="нет factorio-rcon-py (зависимость пакета сервера)")

import live_client as lc  # noqa: E402
import server_client as sc  # noqa: E402
from conftest import PASSWORD, PC_DIR  # noqa: E402
from e2e_world import World, ore_rect  # noqa: E402

MINER = "electric-mining-drill"
SCEN_DIR = os.path.join(PC_DIR, "scenarios")


def load(name):
    mod = lc.load_scenario(name, SCEN_DIR)
    mod.E.VISIBLE_WAIT_S = 0.05
    return mod


@pytest.fixture
def server(fake_rcon, tmp_path):
    """Клиент сценария поверх настоящего Core. → make(world, module, stand=None) -> (client, slot_dir, secrets)."""
    made = []

    def make(world, module, stand=None):
        srv = fake_rcon(handler=world.handler)
        d = tmp_path / ("fp-live-%d" % (len(made) + 1))
        (d / "out").mkdir(parents=True)
        (d / "rcon.pw").write_text(PASSWORD, encoding="utf-8")
        live = lc.LiveClient(srv.port, PASSWORD, timeout=5)
        live.connect()
        secrets_out = []
        client = sc.make_client(live, module, secrets_out, str(d), srv.port, stand or {},
                                str(d / "out" / "server.log"))
        made.append((client, live))
        return client, d, secrets_out

    yield make
    for client, live in made:
        client.close()
        live.close()


# ------------------------------------------------------------ e2e_mcp

def test_mcp_scenario_passes_against_the_model(server):
    world = World()
    scen = load("e2e_mcp")
    client, d, secrets_out = server(world, scen)
    res = scen.run(client)
    assert res["ok"] is True, res
    assert [s["step"] for s in res["steps"]] == [name for name, _ in scen.STEPS]
    assert res["transport"] == "mcp" and res["server_calls"] > 10
    walk = next(s for s in res["steps"] if s["step"] == "walk")["info"]
    assert walk["job"] == 1 and world.helpers["e2e"]["state"] == "removed"
    brief = next(s for s in res["steps"] if s["step"] == "brief")["info"]
    assert brief["notes_chars"] == 0 and brief["notes_missing"]          # forge не подключён — не ошибка
    # ключ помощника в мод не уходит и в результат не попадает
    assert len(secrets_out) == 1 and len(secrets_out[0]) >= 32
    assert secrets_out[0] not in json.dumps(res) and PASSWORD not in json.dumps(res)
    assert world.ops.count("act") == 1                                   # отказы сервера до мода не дошли
    # журнал вызовов сервера: без ключа
    calls = (d / "fp-home" / "logs" / "e2e.jsonl").read_text(encoding="utf-8")
    assert "partner_act" in calls and secrets_out[0] not in calls


def test_mcp_scenario_catches_a_helper_that_did_not_move(server):
    world = World()
    world.do_walk = lambda h, a: {"pos": dict(h["pos"]), "walked": 0}     # «дошёл», но стоит на месте
    scen = load("e2e_mcp")
    client, _, _ = server(world, scen)
    res = scen.run(client)
    assert res["ok"] is False and "walk" in res["failed"]
    assert "remove" in [s["step"] for s in res["steps"]]                  # остальные шаги всё равно прошли


def test_mcp_scenario_needs_the_server_runner(fake_rcon):
    world = World()
    srv = fake_rcon(handler=world.handler)
    with lc.LiveClient(srv.port, PASSWORD, timeout=5) as plain:
        res = load("e2e_mcp").run(plain)
    assert res["ok"] is False and res["error"]["kind"] == "setup" and not srv.commands


# ------------------------------------------------------------ e2e_forge

def test_forge_unsupported_is_reported_verbatim(server):
    """forge не подключён (как на машине без профиля): причина — в результат, сценарий красный."""
    world = World(ore={"iron-ore": ore_rect(30, 0, 14, 14)})
    scen = load("e2e_forge")
    client, _, _ = server(world, scen)
    res = scen.run(client)
    assert res["ok"] is False and res["outcome"] == "forge_unsupported"
    assert res["forge"]["supported"] is False and "FP_FORGE" in res["forge"]["reason"]
    assert res["forge_setup"] == {"configured": False, "checkout_found": False, "venv_found": False,
                                  "home_set": False, "profile_set": False}
    assert res["plans"][0]["resource"] == "iron-ore"
    assert not world.entities and "build_blueprint" not in [do for do, _ in world.acts]


def fake_forge(shift=(0, 0)):
    """Модуль с Python-контрактом MCP.md (plan / load_plan / brief_notes): раскладку считает настоящий
    forge.py, а «CLI forge» заменён кодированием чертежа на месте."""
    from factorio_partner import forge as real

    store = {}
    mod = types.ModuleType("fp_fake_forge")

    def plan(task, resource=None, patch=None, options=None, *, config):
        req = real.parse_args({"task": task, "resource": resource, "patch": patch, "options": options})
        if isinstance(req, dict):
            return req
        layout = real.mining_layout(req)
        size = real.DRILLS[req.drill].size
        ents = []
        for e in layout.entities:
            s = size if e.name == req.drill else 1
            item = {"name": e.name, "position": {"x": e.x - layout.left + s / 2, "y": e.y - layout.top + s / 2}}
            if e.direction is not None:
                item["direction"] = e.direction
            ents.append(item)
        items = {}
        for e in layout.entities:
            items[e.name] = items.get(e.name, 0) + 1
        plan_id = "p-%016x" % (len(store) + 1)
        store[plan_id] = load("e2e_ghosts").E.encode_blueprint(ents)
        anchor = layout.anchor
        return {"plan": plan_id, "anchor": {"x": anchor["x"] + shift[0], "y": anchor["y"] + shift[1]},
                "direction": 0, "items": items, "size": {"w": layout.width, "h": layout.height},
                "summary": "тестовая раскладка", "blueprint": store[plan_id]}

    def load_plan(plan_id, *, config):
        return store[plan_id]

    def brief_notes(config):
        return {"profile": "test", "notes": "заметки хозяина", "truncated": False}

    mod.plan, mod.load_plan, mod.brief_notes, mod.store = plan, load_plan, brief_notes, store
    sys.modules[mod.__name__] = mod
    return mod


@pytest.fixture
def forge_module():
    made = []

    def make(**kw):
        mod = fake_forge(**kw)
        made.append(mod)
        return mod

    yield make
    for mod in made:
        sys.modules.pop(mod.__name__, None)


def test_forge_plan_to_built_drills(server, forge_module):
    world = World(ore={"iron-ore": ore_rect(30, 0, 14, 14)})
    scen = load("e2e_forge")
    client, _, _ = server(world, scen)
    forge = forge_module()
    client.core.forge_module = forge.__name__
    res = scen.run(client)
    assert res["ok"] is True, res
    assert res["outcome"] == "planned" and res["resource"] == "iron-ore"
    items = res["plan"]["items"]
    assert items == {MINER: 2, "fast-transport-belt": 3, "medium-electric-pole": 4}
    assert res["inventory"]["spent"] == items and res["on_map"]["inside_window"] == items
    assert res["on_map"]["outside_window"] == 0 and sorted(d["dir"] for d in res["on_map"]["drills"]) == [4, 12]
    # чертёж ушёл в мод частями через blob_put самим сервером; агенту строка не показывалась
    assert world.ops.count("blob_put") >= 2
    text = json.dumps(res)
    assert all(bp not in text for bp in forge.store.values()) and "blueprint" not in res["plans"][0]
    builds = [a for do, a in world.acts if do == "build_blueprint"]
    assert builds[0].get("dry_run") is True and builds[-1].get("mode") == "hand"
    assert all("plan" not in a and a["blob"].startswith("bp-") for a in builds)


def test_forge_needs_ore_the_drill_can_mine(server, forge_module):
    """Без руды (или только с вольфрамом) план не запрашивается: бур на голой земле не поставить."""
    world = World(ore={"tungsten-ore": ore_rect(30, 0, 14, 14)})
    scen = load("e2e_forge")
    client, _, _ = server(world, scen)
    client.core.forge_module = forge_module().__name__
    res = scen.run(client)
    assert res["ok"] is False and res["error"]["kind"] == "setup" and "на руде" in res["error"]["text"]
    assert "plans" not in res and not world.acts


def test_forge_wrong_anchor_is_caught(server, forge_module):
    """anchor из плана не в центре окна: чертёж встал бы со сдвигом — сценарий это ловит до стройки."""
    world = World(ore={"iron-ore": ore_rect(30, 0, 14, 14)})
    scen = load("e2e_forge")
    client, _, _ = server(world, scen)
    client.core.forge_module = forge_module(shift=(3, 0)).__name__
    res = scen.run(client)
    assert res["ok"] is False and "anchor" in res["reasons"][0]
    assert not world.entities


def test_forge_built_outside_the_window_is_caught(server, forge_module):
    """Мод поставил чертёж не туда, куда просили (расхождение привязки): сверка с картой красная."""
    world = World(ore={"iron-ore": ore_rect(30, 0, 14, 14)})
    orig = world._layout
    world._layout = lambda ents, anchor: orig(ents, {"x": anchor["x"] + 5, "y": anchor["y"]})
    scen = load("e2e_forge")
    client, _, _ = server(world, scen)
    client.core.forge_module = forge_module().__name__
    res = scen.run(client)
    assert res["ok"] is False and any("не туда" in r for r in res["reasons"])


# ------------------------------------------------------------ server_client

def test_tool_errors_and_whitelist(server):
    world = World()
    scen = load("e2e_mcp")
    client, _, _ = server(world, scen)
    with pytest.raises(sc.ToolError) as ei:
        client.tool("state")                       # помощника ещё нет
    assert ei.value.code == "no_helper"
    assert client.try_tool("state") == {"ok": False, "error": {"code": "no_helper", "text": "no such helper"}}
    with pytest.raises(sc.ToolError) as ei:
        client.tool_as("state", "e2e", "wrong-key-" * 5)
    assert ei.value.code == "access denied"
    for bad in ("admin_spawn", "raw", "_tool", "close"):
        with pytest.raises(lc.LiveClientError):
            client.tool(bad)
    with pytest.raises(lc.LiveClientError):
        client.admin("attach", helper="e2e", player="x")
    assert client.admin("spawn", helper="e2e")["data"]["helper"] == "e2e"
    assert client.tool("state")["helper"] == "e2e"
    assert client.call_ok("hello")["proto"] == 1   # прямые конверты остаются доступны
    assert "key" not in repr(client).lower() and client._key not in repr(client)


def test_no_time_left_is_a_transport_error(server):
    world = World()
    client, _, _ = server(world, load("e2e_mcp"))
    client.live.deadline = 0.0
    with pytest.raises(lc.LiveClientError) as ei:
        client.admin("hello")
    assert ei.value.kind == "transport"


def test_bad_helper_name_is_refused(fake_rcon, tmp_path):
    world = World()
    srv = fake_rcon(handler=world.handler)
    (tmp_path / "rcon.pw").write_text(PASSWORD, encoding="utf-8")
    module = types.SimpleNamespace(HELPER="Bad Name")
    with pytest.raises(lc.LiveClientError):
        sc.make_client(object(), module, [], str(tmp_path), srv.port)
    assert not (tmp_path / "fp-home" / "helpers.json").exists()


def test_run_scenario_writes_results_and_cleans_the_key(fake_rcon, tmp_path, monkeypatch):
    world = World()
    srv = fake_rcon(handler=world.handler)
    monkeypatch.setattr(lc, "RCON_BASE_PORT", srv.port - 1)
    d = tmp_path / "fp-live-1"
    d.mkdir()
    (d / "rcon.pw").write_text(PASSWORD, encoding="utf-8")
    sd = tmp_path / "scen"
    sd.mkdir()
    (sd / "s_key.py").write_text(
        "HELPER = 'k1'\n"
        "def run(client):\n"
        "    client.admin('spawn', helper='k1')\n"
        "    st = client.tool('state')\n"
        "    return {'ok': st['helper'] == 'k1', 'leak': client._key, 'forge': client.forge}\n", encoding="utf-8")
    res = sc.run_scenario(1, str(d), "s_key", 30, scenario_directory=str(sd))
    assert res["ok"] is True and res["leak"] == "<private>"
    raw = (d / "out" / "results-1.json").read_text(encoding="utf-8")
    saved = json.loads(raw)
    assert saved["ok"] is True and saved["leak"] == "<private>" and PASSWORD not in raw
    assert not (d / "fp-home" / "helpers.json").exists()            # ключ жил один запуск
    assert "partner_state" in (d / "out" / "calls-1.jsonl").read_text(encoding="utf-8")
    assert (d / "out" / "server-1.log").exists()
    assert all(c.startswith("/partner {") for c in srv.commands)


def test_cli_run(fake_rcon, tmp_path, monkeypatch, capsys):
    world = World()
    srv = fake_rcon(handler=world.handler)
    monkeypatch.setattr(lc, "RCON_BASE_PORT", srv.port - 1)
    d = tmp_path / "fp-live-2"
    d.mkdir()
    (d / "rcon.pw").write_text(PASSWORD, encoding="utf-8")
    monkeypatch.setattr(sc, "run_scenario", lambda slot, slot_dir, scenario, timeout: {"ok": slot == 2})
    assert sc.main(["run", "--slot", "2", "--dir", str(d), "--scenario", "e2e_mcp"]) == 0
    assert json.loads(capsys.readouterr().out)["ok"] is True
    assert sc.main(["run", "--slot", "12", "--dir", str(d), "--scenario", "e2e_mcp"]) == 2
