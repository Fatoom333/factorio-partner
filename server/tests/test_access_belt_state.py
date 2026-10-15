"""Server side: ``partner_access``, ``plan_belt`` and the new arguments of
``build_blueprint`` in the whitelist, ``body`` / ``module_errors`` in ``partner_state``, the short
rules of ``partner_brief`` and the ``forge_too_old`` answer of an old forge."""
import io
import json
import subprocess
import sys
import types
from pathlib import Path

import pytest

from factorio_partner import brief, cli, forge
from factorio_partner import validate as V
from factorio_partner.core import Core
from factorio_partner.errors import PartnerError
from factorio_partner.server import build_server

from conftest import KEY, make_bridge
from fake_rcon import FakeModError

REPO = Path(__file__).resolve().parent.parent.parent
AREA = {"left_top": {"x": 100, "y": 28}, "right_bottom": {"x": 141, "y": 55}}
ACCESS_ANSWER = {"area": AREA, "surface": "vulcanus", "land": 812, "liquid": 460, "liquids": {"lava": 460},
                 "enclosed": False,
                 "exits": [{"side": "south", "pos": {"x": 118, "y": 70}, "width": 14, "neck": "wide"},
                           {"side": "west", "pos": {"x": 96, "y": 41}, "width": 3, "neck": "narrow"}],
                 "best": "south", "reachable": True, "warnings": ["narrow_access:west"]}
USAGE = (b"usage: factorio-forge [-h] {build,check} ...\n"
         b"factorio-forge: error: argument command: invalid choice: 'notes' (choose from 'build', 'check')\n")


def last_env(fake, op=None):
    for env in reversed(fake.mod.requests):
        if op is None or env.get("op") == op:
            return env
    raise AssertionError(f"no request {op}")


def sent(fake, op):
    return [e for e in fake.mod.requests if e.get("op") == op]


async def code_of(coro):
    with pytest.raises(PartnerError) as ei:
        await coro
    return ei.value


def install_access(fake, answer=None):
    fake.mod.handlers["access"] = lambda args, env: dict(answer or ACCESS_ANSWER)


# ---------------------------------------------------------------- partner_access

async def test_access_passes_only_given_args(core, fake):
    install_access(fake)
    r = await core.op_access("h1", KEY)
    assert r["best"] == "south" and r["liquids"] == {"lava": 460} and r["warnings"] == ["narrow_access:west"]
    env = last_env(fake, "access")
    assert env["helper"] == "h1" and env["args"] == {}
    await core.op_access("h1", KEY, area=AREA)
    assert last_env(fake, "access")["args"] == {"area": AREA}
    await core.op_access("h1", KEY, radius=48.0, center={"x": 5, "y": -7})
    assert last_env(fake, "access")["args"] == {"radius": 48, "center": {"x": 5, "y": -7}}
    await core.op_access("h1", KEY, near="player")
    assert last_env(fake, "access")["args"] == {"near": "player"}


@pytest.mark.parametrize("kw,code", [
    ({"area": AREA, "radius": 8}, "bad_args"),
    ({"area": AREA, "center": {"x": 0, "y": 0}}, "bad_args"),
    ({"area": AREA, "near": "player"}, "bad_args"),
    ({"center": {"x": 0, "y": 0}, "near": "player"}, "bad_args"),
    ({"near": "owner"}, "bad_args"),
    ({"radius": 0}, "bad_args"),
    ({"radius": 2.5}, "bad_args"),
    ({"radius": True}, "bad_args"),
    ({"radius": 65}, "limit"),
    ({"area": {"left_top": {"x": 0, "y": 0}, "right_bottom": {"x": 129, "y": 5}}}, "limit"),
    ({"area": {"left_top": {"x": 5, "y": 0}, "right_bottom": {"x": 5, "y": 5}}}, "bad_args"),
    ({"area": "here"}, "bad_args"),
    ({"center": {"x": 0}}, "bad_args"),
])
async def test_access_rejects_before_the_mod(core, fake, kw, code):
    install_access(fake)
    assert (await code_of(core.op_access("h1", KEY, **kw))).code == code
    assert sent(fake, "access") == []


async def test_access_needs_key_and_keeps_mod_errors(core, fake):
    def refuse(args, env):
        raise FakeModError("not_charted", "area is not charted")
    fake.mod.handlers["access"] = refuse
    assert (await code_of(core.op_access("h1", "w" * 40))).code == "access denied"
    assert sent(fake, "access") == []
    e = await code_of(core.op_access("h1", KEY))
    assert e.code == "not_charted" and "charted" in e.text


async def test_access_response_too_large_has_a_hint(core, fake):
    install_access(fake, dict(ACCESS_ANSWER, liquids={f"tile-{i}": 1 for i in range(3000)}))
    e = await code_of(core.op_access("h1", KEY))
    assert e.code == "response too large" and "area" in e.text


async def test_access_tool_and_cli(core, fake):
    install_access(fake)
    mcp = build_server(core)
    tools = {t.name: t for t in await mcp.list_tools()}
    assert set(tools["partner_access"].inputSchema["properties"]) == {"helper", "key", "area", "radius", "center",
                                                                     "near"}
    await mcp.call_tool("partner_access", {"helper": "h1", "key": KEY, "radius": 16, "near": "player"})
    assert last_env(fake, "access")["args"] == {"radius": 16, "near": "player"}
    out = io.StringIO()
    req = {"tool": "partner_access", "helper": "h1", "key": KEY, "area": AREA}
    rc = await cli.run(core, io.StringIO(json.dumps(req)), out, False)
    assert rc == 0 and json.loads(out.getvalue())["result"]["best"] == "south"


def test_every_tool_of_the_contract_is_served():
    """Таблица инструментов MCP.md, сервер и отладочный CLI — один и тот же список."""
    doc = (REPO / "docs" / "MCP.md").read_text(encoding="utf-8")
    table = doc.split("| tool |", 1)[1].split("\n\n", 1)[0]
    in_doc = {line.split("`")[1] for line in table.splitlines() if line.startswith("| `partner_")}
    assert "partner_access" in in_doc
    assert set(cli.TOOLS) == in_doc


# ---------------------------------------------------------------- plan_belt and build_blueprint

@pytest.mark.parametrize("args", [
    {"from": "patch", "to": {"x": 10, "y": -4}},
    {"from": {"x": 1.5, "y": 2.5}, "to": {"x": 10, "y": -4}, "belt": "fast-transport-belt", "lanes": 4,
     "underground": "never", "start_direction": "west", "dry_run": True},
    {"from": "patch", "to": {"x": 0, "y": 0}, "lanes": 1, "underground": "prefer"},
])
async def test_plan_belt_goes_to_the_mod_as_given(core, fake, args):
    r = await core.op_act("h1", KEY, "plan_belt", args)
    assert r["job"] == 1
    assert last_env(fake, "act")["args"] == {"do": "plan_belt", "args": args, "replace": False}


@pytest.mark.parametrize("args,code", [
    ({"to": {"x": 1, "y": 1}}, "bad_args"),                                   # from is required
    ({"from": "patch"}, "bad_args"),                                          # to is required
    ({"from": "base", "to": {"x": 1, "y": 1}}, "bad_args"),
    ({"from": "patch", "to": "player"}, "bad_args"),
    ({"from": {"x": 1}, "to": {"x": 1, "y": 1}}, "bad_args"),
    ({"from": "patch", "to": {"x": 1, "y": 1}, "lanes": 0}, "bad_args"),
    ({"from": "patch", "to": {"x": 1, "y": 1}, "lanes": 5}, "limit"),
    ({"from": "patch", "to": {"x": 1, "y": 1}, "lanes": 1.5}, "bad_args"),
    ({"from": "patch", "to": {"x": 1, "y": 1}, "underground": "always"}, "bad_args"),
    ({"from": "patch", "to": {"x": 1, "y": 1}, "start_direction": 4}, "bad_args"),
    ({"from": "patch", "to": {"x": 1, "y": 1}, "belt": "belt [item=x]"}, "bad_args"),
    ({"from": "patch", "to": {"x": 1, "y": 1}, "dry_run": 1}, "bad_args"),
    ({"from": "patch", "to": {"x": 1, "y": 1}, "force": "superforced"}, "bad_args"),
    ({"from": "patch", "to": {"x": 1, "y": 1}, "area": AREA}, "bad_args"),
])
async def test_plan_belt_rejects_before_the_mod(core, fake, args, code):
    assert (await code_of(core.op_act("h1", KEY, "plan_belt", args))).code == code
    assert sent(fake, "act") == []


async def test_build_blueprint_fit_arguments(core, fake):
    args = {"blob": "bp-1", "anchor": {"x": 3, "y": 4}, "search": 0, "rotate": True, "partial": False,
            "mirror": True, "direction": 4, "force": "forced", "dry_run": True}
    await core.op_act("h1", KEY, "build_blueprint", args)
    assert last_env(fake, "act")["args"]["args"] == args
    await core.op_act("h1", KEY, "build_blueprint", {"blob": "bp-1", "anchor": {"x": 3, "y": 4}, "search": 32.0})
    assert last_env(fake, "act")["args"]["args"]["search"] == 32


@pytest.mark.parametrize("extra,code", [
    ({"search": 33}, "limit"),
    ({"search": -1}, "bad_args"),
    ({"search": 1.5}, "bad_args"),
    ({"search": True}, "bad_args"),
    ({"rotate": "yes"}, "bad_args"),
    ({"partial": 1}, "bad_args"),
    ({"mirror": None}, "bad_args"),
    ({"shift": {"dx": 1, "dy": 0}}, "bad_args"),
])
async def test_build_blueprint_fit_arguments_are_checked(core, fake, extra, code):
    args = dict({"blob": "bp-1", "anchor": {"x": 3, "y": 4}}, **extra)
    assert (await code_of(core.op_act("h1", KEY, "build_blueprint", args))).code == code
    assert sent(fake, "act") == []


async def test_partial_is_never_added_by_the_server(core, fake):
    """`partial` — решение хозяина: сервер его не подставляет и не меняет."""
    await core.op_act("h1", KEY, "build_blueprint", {"blob": "bp-1", "anchor": {"x": 3, "y": 4}})
    assert "partial" not in last_env(fake, "act")["args"]["args"]


def test_plan_mining_whitelist_matches_the_contract():
    """Аргументы plan_mining, plan_belt и build_blueprint — ровно строки «Список v1» ACTIONS.md
    (плюс `plan` сервера и `mirror` мода у build_blueprint)."""
    doc = (REPO / "docs" / "ACTIONS.md").read_text(encoding="utf-8")
    for do, extra in (("plan_mining", set()), ("plan_belt", set()), ("build_blueprint", {"plan", "mirror"})):
        row = next(line for line in doc.splitlines() if line.startswith(f"| `{do}` |"))
        cell = row.split("|")[2]
        for name in V.ACTIONS[do][0]:
            assert name in extra or name in cell, (do, name)
    fields = set(V.ACTIONS["plan_mining"][0])
    assert fields == {"resource", "area", "near", "layout", "direction", "miner", "belt", "pole", "pipe",
                      "options", "dry_run"}
    assert V.check_act("plan_mining", {"near": {"x": 1, "y": 2}, "options": {"avoid_water": False}})
    with pytest.raises(PartnerError):
        V.check_act("plan_mining", {"near": {"x": 1, "y": 2}, "direction": "up"})


# ---------------------------------------------------------------- partner_state: body, module_errors

async def test_state_passes_body_and_module_errors(core, fake):
    fake.mod.handlers["state"] = lambda args, env: {"helper": "h1", "pos": {"x": 1, "y": 2}, "body": "player",
                                                    "module_errors": 3}
    r = await core.op_state("h1", KEY)
    assert r["body"] == "player" and r["module_errors"] == 3 and "tick" in r and "seq" in r
    assert [e["op"] for e in fake.mod.requests if e["op"] != "hello"] == ["state"]


async def test_state_fills_them_in_for_a_mod_that_does_not_send_them(core, fake):
    fake.mod.handlers["state"] = lambda args, env: {"helper": "h1", "pos": {"x": 1, "y": 2}}
    fake.mod.handlers["hello"] = lambda args, env: {"proto": 1, "seq": 0, "module_errors": 2}
    fake.mod.handlers["helper_list"] = lambda args, env: {"helpers": [
        {"id": "h2", "state": "alive", "body": "character"}, {"id": "h1", "state": "alive", "body": "player"}]}
    r = await core.op_state("h1", KEY)
    assert r["module_errors"] == 2 and r["body"] == "player" and r["pos"] == {"x": 1, "y": 2}
    assert last_env(fake, "helper_list").get("helper") is None        # helper_list is not a helper op


async def test_state_survives_when_the_extras_are_not_available(core, fake):
    fake.mod.handlers["state"] = lambda args, env: {"helper": "h1", "pos": {"x": 1, "y": 2}, "body": "ghost",
                                                    "module_errors": "many"}

    def refuse(args, env):
        raise FakeModError("unknown_op", "helper_list")
    fake.mod.handlers["helper_list"] = refuse
    r = await core.op_state("h1", KEY)
    assert r["pos"] == {"x": 1, "y": 2} and "body" not in r and "module_errors" not in r


# ---------------------------------------------------------------- partner_brief

def test_brief_rules_are_short_and_point_to_the_agent_prompt():
    rules = brief.RULES
    assert len(rules.encode("utf-8")) < 2500
    for word in ("Честность", "без телепорта", "без предметов из воздуха", "normal", "owner:true", "partner_act",
                 "partner.md", "верен он"):
        assert word in rules, word
    # рабочих рецептов в кратких правилах нет — они в промпте агента
    for word in ("build_blueprint", "plan_mining", "MPP", "repeated_failure"):
        assert word not in rules, word
    assert (REPO / brief.RULES_FULL).is_file()


async def test_brief_has_rules_link_notes_and_style(cfg, fake, home, monkeypatch):
    mod = types.ModuleType("fake_forge_r33")
    mod.brief_notes = lambda config: {"profile": "vulkan-start", "notes": "Лава слева.", "truncated": False}
    monkeypatch.setitem(sys.modules, "fake_forge_r33", mod)
    (home / "style.md").write_text("Коротко.", encoding="utf-8")
    c = Core(cfg, make_bridge(cfg), forge_module="fake_forge_r33")
    r = await c.op_brief("h1", KEY)
    assert r["rules"] == brief.RULES and r["rules_full"] == ".claude/agents/partner.md"
    assert r["notes"] == "Лава слева." and r["style"] == "Коротко." and "reason" not in r
    await c.close()


async def test_brief_with_an_old_forge_has_empty_notes_and_the_reason(cfg, fake, monkeypatch):
    mod = types.ModuleType("fake_forge_old")
    mod.brief_notes = lambda config: {"profile": None, "notes": "", "truncated": False, "reason": "forge_too_old"}
    mod.plan = lambda *a, config: {"supported": False, "reason": "forge_too_old"}
    monkeypatch.setitem(sys.modules, "fake_forge_old", mod)
    c = Core(cfg, make_bridge(cfg), forge_module="fake_forge_old")
    r = await c.op_brief("h1", KEY)
    assert r["notes"] is None and r["reason"] == "forge_too_old" and r["notes_missing"] == "forge_too_old"
    p = await c.op_plan("h1", KEY, resource={"name": "iron-ore", "area": AREA})
    assert p == {"supported": False, "reason": "forge_too_old"}
    await c.close()


# ---------------------------------------------------------------- forge.py: an old forge

class _Cfg:
    def __init__(self, home, forge_path="C:/forge", profile=None):
        self.home, self.forge, self.forge_profile, self.forge_home = home, forge_path, profile, None


def _old_forge(monkeypatch, refuse=("notes", "list-profiles"), stderr=USAGE, rc=2):
    calls = []

    def run(forge_path, argv, cwd, timeout, **kw):
        calls.append(list(argv))
        if argv[0] in refuse:
            return subprocess.CompletedProcess(argv, rc, b"", stderr)
        if argv[0] == "list-profiles":
            return subprocess.CompletedProcess(argv, 0, b"* vulkan-start (from X)\n", b"")
        raise AssertionError(argv)

    monkeypatch.setattr(forge, "_run_forge", run)
    return calls


def test_old_forge_without_notes_gives_empty_notes_and_no_raw_output(tmp_path, monkeypatch):
    _old_forge(monkeypatch)
    out = forge.brief_notes(_Cfg(tmp_path))
    assert out == {"profile": None, "notes": "", "truncated": False, "reason": "forge_too_old"}
    out = forge.brief_notes(_Cfg(tmp_path, profile="krastorio2"))
    assert out["reason"] == "forge_too_old" and out["notes"] == ""
    assert "usage" not in json.dumps(out) and "invalid choice" not in json.dumps(out)


def test_old_forge_without_profiles_is_not_supported(tmp_path, monkeypatch):
    calls = _old_forge(monkeypatch)
    out = forge.plan("mining", {"name": "iron-ore", "area": AREA}, config=_Cfg(tmp_path))
    assert out == {"supported": False, "reason": "forge_too_old"}
    assert calls == [["list-profiles"]]                       # до build дело не дошло
    assert not list((tmp_path / "plans").glob("p-*"))


def test_old_forge_without_a_build_flag_is_not_supported(tmp_path, monkeypatch):
    err = b"usage: factorio-forge build [-h] plan\nfactorio-forge build: error: unrecognized arguments: --no-render\n"
    calls = _old_forge(monkeypatch, refuse=("build",), stderr=err)
    out = forge.plan("mining", {"name": "iron-ore", "area": AREA}, config=_Cfg(tmp_path))
    assert out == {"supported": False, "reason": "forge_too_old"}
    assert [c[0] for c in calls] == ["list-profiles", "build"]


@pytest.mark.parametrize("rc,stderr", [
    (1, b"usage: forge ...\nerror: invalid choice: 'notes'\n"),      # не код разбора аргументов
    (2, "нет активного профиля\n".encode("utf-8")),                  # отказ самого forge, не разбора
    (1, b"Traceback (most recent call last):\nRuntimeError: no active profile\n"),
])
def test_other_forge_failures_are_not_called_old(tmp_path, monkeypatch, rc, stderr):
    _old_forge(monkeypatch, stderr=stderr, rc=rc)
    out = forge.brief_notes(_Cfg(tmp_path))
    assert out["notes"] == "" and out["reason"] != "forge_too_old" and out["reason"].startswith("forge notes")
    out = forge.plan("mining", {"name": "iron-ore", "area": AREA}, config=_Cfg(tmp_path))
    assert out["supported"] is False and out["reason"] != "forge_too_old"


def test_too_old_detector():
    def proc(rc, err):
        return subprocess.CompletedProcess(["x"], rc, b"", err)
    assert forge._too_old(proc(2, USAGE))
    assert forge._too_old(proc(2, b"Usage: forge [OPTIONS] COMMAND\n\nError: No such command 'notes'.\n"))
    assert not forge._too_old(proc(0, USAGE))
    assert not forge._too_old(proc(2, b""))
    assert not forge._too_old(proc(2, None))


# ---------------------------------------------------------------- docstrings the agent reads

async def test_tool_descriptions_carry_the_contract_hints(core):
    tools = {t.name: t.description for t in await build_server(core).list_tools()}
    assert "имя помощника" in tools["partner_say"]
    assert "plan_belt" in tools["partner_act"] and "partial" in tools["partner_act"]
    assert "body" in tools["partner_state"] and "module_errors" in tools["partner_state"]
    assert "forge_too_old" in tools["partner_plan"] and "forge_too_old" in tools["partner_brief"]
    assert "narrow" in tools["partner_access"] and "enclosed" in tools["partner_access"]


# ---------------------------------------------------------------- admin calls live in core.py

async def test_admin_limit_and_attach_are_core_functions(core, fake):
    fake.mod.handlers["helper_limit"] = lambda args, env: {"max": args["max"], "alive": 0}
    fake.mod.handlers["helper_attach"] = lambda args, env: {"helper": env["helper"], "surface": "nauvis",
                                                             "pos": {"x": 1, "y": 2}}
    r = await core.admin_limit(3)
    assert r["data"] == {"max": 3, "alive": 0} and last_env(fake, "helper_limit")["args"] == {"max": 3}
    r = await core.admin_attach("h2", "Second")
    env = last_env(fake, "helper_attach")
    assert env["helper"] == "h2" and env["args"] == {"player": "Second"} and r["data"]["helper"] == "h2"
    assert (await code_of(core.admin_limit(17))).code == "limit"
    assert (await code_of(core.admin_attach("H2", "Second"))).code == "bad_args"
    assert (await code_of(core.admin_attach("h2", "a\nb"))).code == "bad_args"
    assert len(sent(fake, "helper_limit")) == 1 and len(sent(fake, "helper_attach")) == 1
    # служебные инструменты есть только у сервера с --admin
    names = {t.name for t in await build_server(core).list_tools()}
    assert not any(n.startswith("admin_") for n in names)
    admin = {t.name for t in await build_server(core, admin=True).list_tools()}
    assert {"admin_limit", "admin_attach"} <= admin
