"""Сценарий rates_live против фейкового RCON."""
from __future__ import annotations

import json
import os

import pytest

import live_client as lc
from conftest import PASSWORD, PC_DIR


def load():
    return lc.load_scenario("rates_live", os.path.join(PC_DIR, "scenarios"))


def _model(online=True, break_area=False, fail_surface=False):
    seen = []

    def handler(cmd):
        if cmd == "/quit":
            return None
        env = json.loads(cmd[len("/partner "):])
        op, args = env["op"], env.get("args") or {}
        seen.append((op, args))

        def ok(data):
            return json.dumps({"v": 1, "ok": True, "tick": 1, "seq": 0, "id": env["id"], "data": data})

        if op == "hello":
            return ok({"owner": "Tartaluga", "mod": "factorio-partner 0.1.0",
                       "players": [{"index": 1, "name": "Tartaluga", "online": online,
                                    "surface": "nauvis", "pos": {"x": 10.5, "y": -3}}]})
        assert op == "rates"
        if args["scope"] == "surface":
            if fail_surface:
                return json.dumps({"v": 1, "ok": False, "tick": 1, "seq": 0, "id": env["id"],
                                   "error": {"code": "internal", "text": "get_flow_count"}})
            return ok({"scope": "surface", "surface": "nauvis", "period": args["period"],
                       "items": {"iron-plate": {"made": 1, "used": 0}}, "fluids": {}, "truncated": False})
        area = {"left_top": {"x": 0, "y": 0}, "right_bottom": {"x": 1, "y": 1}}
        d = {"scope": "area", "surface": "nauvis", "area": area, "per": "1m", "machines": [], "net": {},
             "nominal": True, "hidden": 0, "idle": 0, "truncated": False}
        if break_area:
            del d["per"]
        return ok(d)

    handler.seen = seen
    return handler


def test_rates_live_ok_owner_online(fake_rcon):
    h = _model()
    srv = fake_rcon(handler=h)
    with lc.LiveClient(srv.port, PASSWORD, timeout=5) as c:
        res = load().run(c)
    assert res["ok"] is True, res
    rates = [a for op, a in h.seen if op == "rates"]
    assert [a["period"] for a in rates] == ["1m", "10m", "1m"]
    assert all("surface" not in a for a in rates)  # хозяин онлайн: без явной поверхности
    assert rates[2]["area"]["left_top"] == {"x": -21.5, "y": -35.0}


def test_rates_live_offline_passes_surface(fake_rcon):
    h = _model(online=False)
    srv = fake_rcon(handler=h)
    with lc.LiveClient(srv.port, PASSWORD, timeout=5) as c:
        res = load().run(c)
    assert res["ok"] is True, res
    assert all(a["surface"] == "nauvis" for op, a in h.seen if op == "rates")


@pytest.mark.parametrize("kw", [{"break_area": True}, {"fail_surface": True}])
def test_rates_live_failures(fake_rcon, kw):
    srv = fake_rcon(handler=_model(**kw))
    with lc.LiveClient(srv.port, PASSWORD, timeout=5) as c:
        res = load().run(c)
    assert res["ok"] is False and res["reasons"]
