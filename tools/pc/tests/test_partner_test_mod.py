"""Тесты тестового мода mod/partner-test под lupa (Lua 5.2, как в Factorio). Без lupa — пропуск."""
from __future__ import annotations

import json
import os

import pytest

from conftest import REPO

lupa = pytest.importorskip("lupa")
try:
    from lupa import lua52 as lua_impl
except ImportError:  # pragma: no cover
    from lupa import lua53 as lua_impl

CONTROL = os.path.join(REPO, "mod", "partner-test", "control.lua")

STUBS = r"""
local function new_force(name)
  local f = { name = name, charted = {}, friends = {}, ceasefire = {}, chart_calls = 0 }
  function f.is_chunk_charted(surface, c)
    local x, y = c.x or c[1], c.y or c[2]
    return f.charted[surface.name .. ":" .. x .. ":" .. y] == true
  end
  function f.chart(surface, area)
    f.chart_calls = f.chart_calls + 1
    local lt, rb = area[1], area[2]
    for cx = math.floor(lt[1] / 32), math.floor(rb[1] / 32) do
      for cy = math.floor(lt[2] / 32), math.floor(rb[2] / 32) do
        f.charted[surface.name .. ":" .. cx .. ":" .. cy] = true
      end
    end
  end
  function f.set_friend(o, v) f.friends[o.name] = v end
  function f.set_cease_fire(o, v) f.ceasefire[o.name] = v end
  return f
end

local surface = { name = "vulcanus", valid = true, created = {}, generated = {} }
function surface.is_chunk_generated(c)
  local x, y = c.x or c[1], c.y or c[2]
  return surface.generated[x .. ":" .. y] == true
end
local next_unit = 100
function surface.find_non_colliding_position(name, pos, radius, prec)
  return { x = pos.x + 0.5, y = pos.y }
end
function surface.create_entity(spec)
  next_unit = next_unit + 1
  local e = { name = spec.name, valid = true, position = { x = spec.position.x, y = spec.position.y },
              force = spec.force, surface = surface, unit_number = next_unit, health = 250,
              quality = spec.quality }
  function e.destroy() e.valid = false end
  surface.created[#surface.created + 1] = e
  return e
end

storage = {}
local player_force = new_force("player")
game = {
  tick = 1000,
  forces = { player = player_force },
  -- position/surface — камера удалённого вида (смотрит на другую планету), physical_* — тело.
  players = { [1] = { index = 1, name = "Tartaluga", connected = false,
                      surface = { name = "nauvis", valid = true }, position = { x = -5000, y = 7000 },
                      physical_surface = surface, physical_position = { x = 300.25, y = -30.04 } } },
  connected_players = {},
  printed = {},
}
function game.create_force(name)
  local f = new_force(name)
  game.forces[name] = f
  return f
end
function game.merge_forces(src, dst)
  game.forces[src.name] = nil
  game.merged = (game.merged or 0) + 1
end
function game.get_player(i)
  local p = game.players[i]
  if p and not p.print then
    function p.print(text) game.printed[#game.printed + 1] = text end
  end
  return p
end

script = { active_mods = { ["partner-test"] = "0.2.0" }, nth = {} }
function script.on_init(f) script.init = f end
function script.on_configuration_changed(f) script.cfg = f end
function script.on_nth_tick(n, f) script.nth[n] = f end

commands = { handlers = {} }
function commands.add_command(name, help, fn)
  if commands.handlers[name] then error("command exists: " .. name) end
  commands.handlers[name] = fn
end

rcon = { out = {} }
function rcon.print(text) rcon.out[#rcon.out + 1] = text end

helpers = {}
serpent = { line = function(t) return tostring(t) end }
"""


def _to_py(lua, obj):
    if lua_impl.lua_type(obj) == "table":
        keys = list(obj.keys())
        if keys and all(isinstance(k, int) for k in keys) and sorted(keys) == list(range(1, len(keys) + 1)):
            return [_to_py(lua, obj[k]) for k in sorted(keys)]
        return {str(k): _to_py(lua, obj[k]) for k in keys}
    return obj


def _to_lua(lua, value):
    if isinstance(value, dict):
        t = lua.table()
        for k, v in value.items():
            if v is not None:
                t[k] = _to_lua(lua, v)
        return t
    if isinstance(value, list):
        t = lua.table()
        for i, v in enumerate(value, 1):
            t[i] = _to_lua(lua, v)
        return t
    return value


class Mod:
    def __init__(self, active_mods=None):
        self.lua = lua_impl.LuaRuntime(unpack_returned_tuples=True)
        self.lua.execute(STUBS)
        g = self.lua.globals()

        def json_to_table(text):
            try:
                return _to_lua(self.lua, json.loads(text))
            except ValueError:
                return None

        g.helpers.json_to_table = json_to_table
        g.helpers.table_to_json = lambda t: json.dumps(_to_py(self.lua, t), ensure_ascii=False)
        if active_mods is not None:
            g.script.active_mods = _to_lua(self.lua, active_mods)
        with open(CONTROL, "r", encoding="utf-8") as f:
            src = f.read()
        self.M = self.lua.execute(src)
        # storage мод больше не использует: on_init не регистрируется
        self.g = g

    def handlers(self):
        return dict(self.g.commands.handlers)

    def cmd(self, parameter, player_index=None):
        before = len(self.g.rcon.out)
        c = self.lua.table_from({"name": "partner", "tick": self.g.game.tick})
        if parameter is not None:
            c.parameter = parameter
        if player_index is not None:
            c.player_index = player_index
        self.g.commands.handlers["partner"](c)
        out = list(self.g.rcon.out.values())[before:]
        return out

    def call(self, op, args=None, rid="t-1"):
        out = self.cmd(json.dumps({"v": 1, "id": rid, "op": op, "args": args or {}}))
        assert len(out) == 1, out
        return json.loads(out[0])


def test_registers_partner_only_without_real_mod():
    assert "partner" in Mod().handlers()
    m = Mod(active_mods={"partner-test": "0.2.0", "factorio-partner": "0.1.0"})
    assert "partner" not in m.handlers()
    assert "partner-ping" in m.handlers()


def test_hello_envelope():
    r = Mod().call("hello")
    assert r["ok"] is True and r["id"] == "t-1" and r["v"] == 1
    assert r["data"]["mod"].startswith("partner-test")
    assert r["data"]["players_online"] == 0
    # тело игрока (physical_*), а не камера удалённого вида
    assert r["data"]["players"][0]["pos"] == {"x": 300.3, "y": -30.0}
    assert r["data"]["players"][0]["surface"] == "vulcanus"


def test_big_reply_within_contract():
    m = Mod()
    r = m.call("e_big", {"bytes": 199000})
    assert r["ok"] and r["data"]["bytes"] == 199000 and len(r["data"]["pad"]) == 199000
    out = m.cmd(json.dumps({"v": 1, "id": "b-1", "op": "e_big", "args": {"bytes": 199000}}))
    assert len(out[0].encode("utf-8")) <= 200000
    for bad in (0, 199001, 1.5, "10"):
        assert m.call("e_big", {"bytes": bad})["error"]["code"] == "bad_args"


def test_echo_reports_parameter_length():
    m = Mod()
    param = json.dumps({"v": 1, "id": "e-1", "op": "e_echo", "args": {"pad": "x" * 5000}})
    r = json.loads(m.cmd(param)[0])
    assert r["ok"] and r["data"]["len"] == len(param) and r["data"]["pad"] == 5000


@pytest.mark.parametrize("param, code, has_id", [
    ("not json", "bad_request", False),
    ('{"v":1,"op":"hello"}', "bad_request", False),
    ('{"v":1,"id":"a b","op":"hello"}', "bad_request", False),
    ('{"v":2,"id":"x","op":"hello"}', "version_mismatch", True),
    ('{"v":1,"id":"x","op":"nope"}', "unknown_op", True),
    ('{"v":1,"id":"x","op":"e_echo","args":{}}', "bad_args", True),
    ('{"v":1,"id":"x","op":"hello","args":5}', "bad_request", True),
])
def test_errors(param, code, has_id):
    out = Mod().cmd(param)
    assert len(out) == 1
    r = json.loads(out[0])
    assert r["ok"] is False and r["error"]["code"] == code
    assert ("id" in r) == has_id


def test_empty_parameter():
    r = json.loads(Mod().cmd(None)[0])
    assert r["error"]["code"] == "bad_request"


def test_chat_player_is_rejected():
    m = Mod()
    out = m.cmd('{"v":1,"id":"x","op":"hello"}', player_index=1)
    assert out == []
    assert list(m.g.game.printed.values()) == ["[partner] только для RCON"]


def _generate(m, *chunks):
    surface = m.g.game.players[1].physical_surface
    for x, y in chunks:
        surface.generated[f"{x}:{y}"] = True


def test_chart_find_chart_check_on_player_force():
    m = Mod()
    # игрок 1 в чанке (9, -1); сгенерированы близкий (3 чанка — слишком близко) и далёкий (+12 по x)
    _generate(m, (9 + 3, -1), (9 + 12, -1))
    found = m.call("e_chart", {"mode": "find"})
    assert found["ok"], found
    d = found["data"]
    assert d["chunk"] == {"x": 21, "y": -1} and d["dist"] == 12 and d["force"] == "player"
    pf = m.g.game.forces["player"]
    chk = m.call("e_chart", {"mode": "check", "chunk": d["chunk"]})["data"]
    assert chk["charted"] is False and chk["window"] == 25 and pf.chart_calls == 0
    ch = m.call("e_chart", {"mode": "chart", "chunk": d["chunk"], "radius": 64})["data"]
    assert ch["charted"] is True and ch["window_charted"] == 25 and ch["players_online"] == 0
    assert pf.chart_calls == 1
    # force.chart зовётся только у силы игрока, никаких новых сил и сущностей
    assert list(m.g.game.forces.keys()) == ["player"]
    surface = m.g.game.players[1].physical_surface
    assert len(list(surface.created.keys())) == 0


def test_chart_find_skips_charted_and_reports_not_found():
    m = Mod()
    assert m.call("e_chart", {"mode": "find"})["error"]["code"] == "not_found"
    _generate(m, (9 + 10, -1))
    m.call("e_chart", {"mode": "chart", "chunk": {"x": 19, "y": -1}, "radius": 1})
    assert m.call("e_chart", {"mode": "find"})["error"]["code"] == "not_found"


@pytest.mark.parametrize("args", [
    {}, {"mode": "nope"}, {"mode": "check"}, {"mode": "check", "chunk": {"x": 1}},
    {"mode": "check", "chunk": {"x": 1.5, "y": 2}}, {"mode": "chart", "chunk": {"x": 1, "y": 1}, "radius": 1000},
    {"mode": "chart", "chunk": {"x": 1, "y": 1}, "radius": 0}, {"mode": "chart", "chunk": {"x": 1, "y": 1}, "radius": "9"},
])
def test_chart_bad_args(args):
    m = Mod()
    assert m.call("e_chart", args)["error"]["code"] == "bad_args"
    assert m.g.game.forces["player"].chart_calls == 0


def test_chart_uses_physical_surface_not_camera():
    m = Mod()
    r = m.call("e_chart", {"mode": "check", "chunk": {"x": 0, "y": 0}})["data"]
    assert r["force"] == "player"
    # камера игрока смотрит на другую поверхность; мод её не трогает
    assert m.g.game.players[1].surface.name == "nauvis"


def test_chart_no_valid_surface_is_no_player():
    m = Mod()
    m.lua.execute("game.players[1].physical_surface.valid = false")
    assert m.call("e_chart", {"mode": "find"})["error"]["code"] == "no_player"


def test_chart_no_player_force():
    m = Mod()
    m.lua.execute('game.forces["player"] = nil')
    assert m.call("e_chart", {"mode": "find"})["error"]["code"] == "no_player"


def test_chart_no_players_at_all():
    m = Mod()
    m.lua.execute("game.players[1] = nil")
    assert m.call("e_chart", {"mode": "find"})["error"]["code"] == "no_player"


def test_legacy_cleanup_on_configuration_changed():
    m = Mod()
    m.lua.execute("""
        game.create_force("fp-e-chart")
        local b = { valid = true, destroyed = false }
        b.destroy = function() b.destroyed = true; b.valid = false end
        storage.e = { body = b }
    """)
    assert m.g.script.cfg is not None
    body = m.g.storage.e.body
    m.g.script.cfg()
    assert body.destroyed is True
    assert m.g.storage.e is None
    assert m.g.game.forces["fp-e-chart"] is None


def test_old_chart_ops_removed():
    m = Mod()
    for op in ("e_chart_setup", "e_chart_vision", "e_chart_status", "e_chart_cleanup", "e_chart_probe"):
        assert m.call(op)["error"]["code"] == "unknown_op"
    assert len(list(m.g.script.nth.keys())) == 0  # никаких периодических обработчиков


def test_internal_error_keeps_utf8_and_strips_path():
    m = Mod()
    m.M.ops.e_boom = m.lua.eval('function() error("__partner-test__/control.lua:12: ошибка в моде\\nвторая", 0) end')
    r = m.call("e_boom")
    assert r["error"]["code"] == "internal"
    assert r["error"]["text"] == "ошибка в моде вторая"


@pytest.mark.parametrize("text, expected", [
    ("я" * 150, "я" * 100),            # 2-байтные: ровно 200 байт
    ("a" + "я" * 150, "a" + "я" * 99),  # граница посреди символа -> отступаем
    ("ж€" * 80, "ж€" * 40),             # 2+3 байта
    ("x" * 300, "x" * 200),
    ("коротко", "коротко"),
], ids=["cyr-200", "cyr-shift", "mixed-3byte", "ascii", "short"])
def test_clean_error_cuts_on_char_boundary(text, expected):
    m = Mod()
    out = m.M.clean_error(text)
    if isinstance(out, bytes):
        out = out.decode("utf-8")  # строгая проверка: валидный UTF-8
    assert out == expected
    assert len(out.encode("utf-8")) <= 200


def test_mod_source_has_no_teleport_or_console():
    with open(CONTROL, "r", encoding="utf-8") as f:
        src = f.read()
    code = "\n".join(line.split("--", 1)[0] for line in src.splitlines())
    assert "teleport" not in code
    assert "loadstring" not in code and "load(" not in code
    assert ".insert" not in code  # без предметов из воздуха
