"""Юнит-тесты связки с forge (поток I). forge здесь не нужен: `_run_forge` подменяется."""

from __future__ import annotations

import importlib.util
import json
import math
import os
import subprocess
import sys
from pathlib import Path

import pytest

_SRC = Path(__file__).resolve().parents[1] / "factorio_partner" / "forge.py"


def _load():
    # грузим файл напрямую: forge.py должен работать без остального пакета
    spec = importlib.util.spec_from_file_location("fp_forge_under_test", _SRC)
    mod = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = mod
    spec.loader.exec_module(mod)
    return mod


forge = _load()

AREA = {"left_top": {"x": 100.3, "y": 28}, "right_bottom": {"x": 131, "y": 47.5}}
VEC = {0: (0, -1), 4: (1, 0), 8: (0, 1), 12: (-1, 0)}


def mining(name="iron-ore", area=AREA, field="resource", **options):
    args = {"task": "mining", field: {"name": name, "area": area}}
    if options:
        args["options"] = options
    return args


@pytest.fixture(autouse=True)
def _no_fp_env(monkeypatch):
    for name in ("FP_HOME", "FP_FORGE", "FP_FORGE_PROFILE"):
        monkeypatch.delenv(name, raising=False)


class _Cfg:
    """Как Config сервера: только поля, которые читает forge.py."""

    def __init__(self, home, forge=None, forge_profile=None, forge_home=None):
        self.home, self.forge, self.forge_profile, self.forge_home = home, forge, forge_profile, forge_home


def _plan(args, home, forge_path=None, profile=None):
    """plan() по контракту MCP.md: plan(task, resource, patch, options, *, config)."""
    cfg = _Cfg(home, forge_path, profile)
    return forge.plan(args.get("task"), args.get("resource"), args.get("patch"), args.get("options"),
                      config=cfg)


def _notes(profile, forge_path):
    return forge.brief_notes(_Cfg(Path("unused"), forge_path, profile))


# --- проверка аргументов --------------------------------------------------------------

@pytest.mark.parametrize("args", [
    None,
    [],
    {"task": 1},
    {"task": "mining"},
    {"task": "mining", "resource": {"name": "iron-ore", "area": AREA}, "patch": {"name": "x", "area": AREA}},
    {"task": "mining", "resource": {"name": "iron-ore", "area": AREA}, "extra": 1},
    {"task": "mining", "resource": "iron-ore"},
    mining(name="Iron Ore"),
    mining(name="../etc"),
    mining(name="a" * 65),
    mining(area={"left_top": {"x": 0, "y": 0}}),
    mining(area={"left_top": {"x": "0", "y": 0}, "right_bottom": {"x": 5, "y": 5}}),
    mining(area={"left_top": {"x": True, "y": 0}, "right_bottom": {"x": 5, "y": 5}}),
    mining(area={"left_top": {"x": float("nan"), "y": 0}, "right_bottom": {"x": 5, "y": 5}}),
    mining(area={"left_top": {"x": 0, "y": 0}, "right_bottom": {"x": float("inf"), "y": 5}}),
    mining(area={"left_top": {"x": 5, "y": 5}, "right_bottom": {"x": 5, "y": 9}}),
    mining(area={"left_top": {"x": 0, "y": 0}, "right_bottom": {"x": 300, "y": 5}}),
    mining(direction="up"),
    mining(direction=2),
    mining(direction=True),
    mining(belt="Bad Belt"),
    mining(drill=["x"]),
    {"task": "mining", "resource": {"name": "iron-ore", "area": AREA}, "options": {"speed": 1}},
    {"task": "mining", "resource": {"name": "iron-ore", "area": AREA}, "options": "fast"},
])
def test_bad_args(args):
    with pytest.raises(forge.PlanArgsError) as err:
        forge.parse_args(args)
    assert err.value.code == "bad_args"


@pytest.mark.parametrize("args, word", [
    ({"task": "smelting", "resource": {"name": "iron-ore", "area": AREA}}, "mining"),
    (mining(name="crude-oil"), "P.U.M.P."),
    (mining(name="sulfuric-acid-geyser"), "P.U.M.P."),
    (mining(name="uranium-ore"), "MPP"),
    (mining(drill="pumpjack"), "MPP"),
    (mining(name="tungsten-ore", drill="electric-mining-drill"), "big-mining-drill"),
    (mining(pole="big-electric-pole"), "столб"),
])
def test_unsupported(args, word):
    out = forge.parse_args(args)
    assert out["supported"] is False and word in out["reason"]


def test_defaults_and_patch():
    patch = {"name": "calcite", "center": {"x": 1, "y": 1}, "area": AREA, "tiles": 5, "amount": 9, "dist": 3.0}
    req = forge.parse_args({"task": "mining", "patch": patch})
    assert (req.resource, req.drill, req.belt, req.pole, req.direction) == (
        "calcite", "electric-mining-drill", "transport-belt", "small-electric-pole", 0)
    assert (req.left, req.top, req.width, req.height) == (100, 28, 31, 20)
    assert forge.parse_args(mining(name="tungsten-ore")).drill == "big-mining-drill"
    assert forge.parse_args(mining(direction="East")).direction == 4
    assert forge.parse_args(mining(direction=12)).direction == 12


# --- раскладка ------------------------------------------------------------------------

def _size(name):
    return forge.DRILLS[name].size if name in forge.DRILLS else 1


def _check_layout(req):
    lay = forge.mining_layout(req)
    occupied = {}
    for e in lay.entities:
        s = _size(e.name)
        for dx in range(s):
            for dy in range(s):
                tile = (e.x + dx, e.y + dy)
                assert tile not in occupied, f"наложение в {tile}"
                occupied[tile] = e
        # всё внутри прямоугольника раскладки
        assert lay.left <= e.x and e.x + s <= lay.left + lay.width
        assert lay.top <= e.y and e.y + s <= lay.top + lay.height
    # прямоугольник раскладки покрывает пятно
    assert lay.width >= req.width and lay.height >= req.height
    assert (lay.left, lay.top) == (req.left, req.top)
    assert lay.anchor == {"x": lay.left + lay.width / 2, "y": lay.top + lay.height / 2}

    belts = {(e.x, e.y): e for e in lay.entities if e.name == req.belt}
    assert all(b.direction == req.direction for b in belts.values())
    drills = [e for e in lay.entities if e.name == req.drill]
    assert len(drills) == lay.drills
    s = forge.DRILLS[req.drill].size
    for d in drills:
        vx, vy = VEC[d.direction]
        # тайлы прямо перед серединой передней стороны бура — лента
        cx, cy = d.x + s / 2 + vx * (s / 2 + 0.5), d.y + s / 2 + vy * (s / 2 + 0.5)
        fronts = {(math.floor(cx), math.floor(cy))} if s % 2 else {
            (math.floor(cx - 0.5 * abs(vy)), math.floor(cy - 0.5 * abs(vx))),
            (math.floor(cx + 0.5 * abs(vy) - 1e-9), math.floor(cy + 0.5 * abs(vx) - 1e-9)),
        }
        for t in fronts:
            assert t in belts, f"бур в ({d.x},{d.y}) смотрит мимо ленты: {t}"
    # выходы: за краем раскладки, в них упирается лента, текущая туда
    vx, vy = VEC[req.direction]
    for ex, ey in lay.exits:
        assert (ex, ey) not in occupied
        assert (ex - vx, ey - vy) in belts
    poles = [e for e in lay.entities if e.name == req.pole]
    if forge.DRILLS[req.drill].powered:
        reach, supply = forge.POLES[req.pole]
        centers = [(p.x + 0.5, p.y + 0.5) for p in poles]
        # одна сеть
        seen, todo = {0}, [0]
        while todo:
            i = todo.pop()
            for j, c in enumerate(centers):
                if j not in seen and math.dist(centers[i], c) <= reach:
                    seen.add(j)
                    todo.append(j)
        assert len(seen) == len(centers)
        # каждый бур в зоне питания хотя бы одного столба
        for d in drills:
            assert any(
                px - supply < d.x + s and d.x < px + supply and py - supply < d.y + s and d.y < py + supply
                for px, py in centers
            ), f"бур в ({d.x},{d.y}) без питания"
    else:
        assert poles == []
    return lay


@pytest.mark.parametrize("drill", sorted(forge.DRILLS))
@pytest.mark.parametrize("direction", [0, 4, 8, 12])
@pytest.mark.parametrize("pole", ["small-electric-pole", "medium-electric-pole"])
@pytest.mark.parametrize("area", [
    AREA,
    {"left_top": {"x": -3, "y": -3}, "right_bottom": {"x": 0, "y": 0}},
    {"left_top": {"x": -40.5, "y": 7}, "right_bottom": {"x": -2, "y": 40}},
])
def test_layout_geometry(drill, direction, pole, area):
    req = forge.parse_args(mining(area=area, drill=drill, direction=direction, pole=pole))
    _check_layout(req)


def test_layout_too_many_drills():
    big = {"left_top": {"x": 0, "y": 0}, "right_bottom": {"x": 256, "y": 256}}
    req = forge.parse_args(mining(area=big))
    with pytest.raises(forge.PlanArgsError):
        forge.mining_layout(req)


def test_forge_plan_shape():
    req = forge.parse_args(mining())
    lay = forge.mining_layout(req)
    fp = forge.layout_to_forge_plan(lay, "partner-x")
    assert fp["label"] == "partner-x" and len(fp["entities"]) == len(lay.entities)
    pole = next(e for e in fp["entities"] if e["name"] == "small-electric-pole")
    assert "direction" not in pole
    assert all(isinstance(v, int) for e in fp["entities"] for v in e["position"])


# --- plan() с подменённым forge -------------------------------------------------------

BP = "0eNqrVkrKKU0tKsrMK1GyqlYqLU7NUbJSSs4vzUtRqq0FAHhoCfo="


class FakeForge:
    def __init__(self, active="vulkan-start", findings=(), rc=0, blueprint=BP, write=True, raise_on=None):
        self.active, self.findings, self.rc = active, list(findings), rc
        self.blueprint, self.write, self.raise_on = blueprint, write, raise_on
        self.calls = []

    def __call__(self, forge_path, argv, cwd, timeout, **kw):
        self.kw = kw
        self.calls.append((forge_path, list(argv), Path(cwd), timeout))
        if self.raise_on == argv[0]:
            raise forge.ForgeUnavailable("boom")
        if argv[0] == "list-profiles":
            lines = ["  krastorio2 (from Krastorio2) — data extracted, style not measured"]
            if self.active:
                lines.append(f"* {self.active} (from X) — data extracted, style not measured")
            return subprocess.CompletedProcess(argv, 0, "\n".join(lines).encode(), b"")
        if argv[0] == "build":
            plan_path = Path(argv[1])
            out = Path(argv[argv.index("-o") + 1])
            data = json.loads(plan_path.read_text(encoding="utf-8"))
            self.plan = data
            if self.write:
                out.mkdir(parents=True, exist_ok=True)
                (out / f"{data['label']}.txt").write_text(self.blueprint, encoding="utf-8")
                report = {"label": data["label"], "findings": self.findings, "blueprint": self.blueprint}
                (out / f"{data['label']}.report.json").write_text(json.dumps(report), encoding="utf-8")
            return subprocess.CompletedProcess(argv, self.rc, b"", "сломалось".encode() if self.rc else b"")
        raise AssertionError(argv)


@pytest.fixture
def fake(monkeypatch):
    def install(**kw):
        f = FakeForge(**kw)
        monkeypatch.setattr(forge, "_run_forge", f)
        return f
    return install


def test_plan_ok(tmp_path, fake):
    f = fake(findings=[{"severity": "suspect", "summary": "что-то странно"},
                       {"severity": "note", "summary": "мелочь"}])
    out = _plan(mining(direction="south"), tmp_path, "C:/forge", None)
    assert set(out) == {"plan", "anchor", "direction", "items", "size", "summary"}
    assert forge.PLAN_ID_RE.match(out["plan"])
    assert out["direction"] == 0
    assert BP not in json.dumps(out)              # строка чертежа агенту не уходит
    assert out["items"]["electric-mining-drill"] > 0 and out["items"]["transport-belt"] > 0
    assert "что-то странно" in out["summary"] and "юг" in out["summary"]
    plans = tmp_path / "plans"
    assert (plans / f"{out['plan']}.txt").read_text(encoding="utf-8") == BP
    meta = json.loads((plans / f"{out['plan']}.json").read_text(encoding="utf-8"))
    assert meta["profile"] == "vulkan-start" and meta["flow"] == "south"
    assert BP not in json.dumps(meta)
    # временная папка убрана, остались только план и метаданные
    assert sorted(p.name for p in plans.iterdir()) == sorted([out["plan"] + ".txt", out["plan"] + ".json"])
    # forge звали list-profiles, затем build с --no-render и таймаутом
    assert [c[1][0] for c in f.calls] == ["list-profiles", "build"]
    build = f.calls[1]
    assert build[1][2] == "-o" and build[1][-1] == "--no-render" and build[3] == forge.BUILD_TIMEOUT_S
    assert forge.load_plan(out["plan"], config=_Cfg(tmp_path)) == BP
    assert len(f.plan["entities"]) == sum(out["items"].values())


def test_plan_ignores_process_env(tmp_path, fake, monkeypatch):
    """Контракт MCP.md: окружение процесса forge.py не читает — только config."""
    f = fake()
    monkeypatch.setenv("FP_HOME", str(tmp_path / "env-home"))
    monkeypatch.setenv("FP_FORGE", "D:/forge-env")
    monkeypatch.setenv("FP_FORGE_PROFILE", "krastorio2")
    out = _plan(mining(), tmp_path / "home", "C:/cfg-forge", "vulkan-start")
    assert "plan" in out and f.calls[0][0] == "C:/cfg-forge"
    assert (tmp_path / "home" / "plans" / f"{out['plan']}.txt").is_file()
    assert not (tmp_path / "env-home").exists()


def test_plan_without_home_is_bad_args(fake):
    fake()
    with pytest.raises(forge.PlanArgsError):
        _plan(mining(), None, "C:/forge", None)


@pytest.mark.parametrize("kw, profile, word", [
    ({"active": None}, None, "активного профиля"),
    ({}, "krastorio2", "krastorio2"),
    ({"raise_on": "list-profiles"}, None, "недоступен"),
    ({"raise_on": "build"}, None, "недоступен"),
    ({"rc": 1}, None, "сломалось"),
    ({"write": False}, None, "не оставил"),
    ({"findings": [{"severity": "problem", "summary": "the poles form 2 separate networks"}]}, None, "networks"),
    ({"blueprint": "<html>"}, None, "не того вида"),
    ({"blueprint": "0" + "a" * forge.MAX_BLUEPRINT_BYTES}, None, "1 МБ"),
])
def test_plan_unsupported(tmp_path, fake, kw, profile, word):
    fake(**kw)
    out = _plan(mining(), tmp_path, "C:/forge", profile)
    assert out["supported"] is False and word in out["reason"], out
    # ничего не сохранилось и временная папка убрана
    assert list((tmp_path / "plans").iterdir()) == []


def test_plan_bad_args_before_forge(tmp_path, fake):
    f = fake()
    with pytest.raises(forge.PlanArgsError):
        _plan(mining(name="Bad"), tmp_path, "C:/forge", None)
    with pytest.raises(forge.PlanArgsError):
        _plan(mining(), tmp_path, "C:/forge", "--force")
    assert _plan({"task": "smelting", "resource": {"name": "x", "area": AREA}}, tmp_path, "C:/f", None)[
        "supported"] is False
    assert f.calls == []


def test_plan_without_forge_venv(tmp_path):
    out = _plan(mining(), tmp_path, str(tmp_path / "no-forge"), None)
    assert out["supported"] is False and ".venv" in out["reason"]
    out = _plan(mining(), tmp_path, "", None)
    assert out["supported"] is False


def test_prune(tmp_path, fake, monkeypatch):
    fake()
    monkeypatch.setattr(forge, "MAX_KEPT_PLANS", 3)
    ids = [_plan(mining(), tmp_path, "C:/forge", None)["plan"] for _ in range(3)]
    plans = tmp_path / "plans"
    (plans / "keep-me.txt").write_text("x")
    for n, pid in enumerate(ids):  # старые раньше
        os.utime(plans / f"{pid}.txt", (1000 + n, 1000 + n))
    forge._prune(plans, keep=2)
    left = sorted(p.name for p in plans.iterdir())
    assert ids[0] + ".txt" not in left and ids[0] + ".json" not in left
    assert ids[1] + ".txt" in left and ids[2] + ".txt" in left and "keep-me.txt" in left


# --- load_plan ------------------------------------------------------------------------

@pytest.mark.parametrize("bad", [None, 5, "", "../plans/p-0000000000000000", "p-XYZ", "p-0000000000000000/..",
                                 "P-0000000000000000", "p-0000000000000000.json"])
def test_load_plan_bad_id(tmp_path, bad):
    with pytest.raises(forge.PlanArgsError):
        forge.load_plan(bad, config=_Cfg(tmp_path))


def test_load_plan_missing(tmp_path):
    with pytest.raises(forge.PlanArgsError, match="нет такого"):
        forge.load_plan("p-0123456789abcdef", config=_Cfg(tmp_path))


# --- вызов subprocess -----------------------------------------------------------------

def test_run_forge_invocation(tmp_path, monkeypatch):
    root = tmp_path / "forge"
    py = root / ".venv" / ("Scripts/python.exe" if sys.platform == "win32" else "bin/python")
    py.parent.mkdir(parents=True)
    py.write_text("")
    seen = {}

    def fake_run(cmd, **kw):
        seen["cmd"], seen["kw"] = cmd, kw
        return subprocess.CompletedProcess(cmd, 0, b"", b"")

    monkeypatch.setattr(forge.subprocess, "run", fake_run)
    forge._run_forge(str(root), ["notes", "vulkan-start"], tmp_path, 7)
    assert seen["cmd"] == [str(py), "-I", "-X", "utf8", "-m", "factorio_forge.cli", "notes", "vulkan-start"]
    kw = seen["kw"]
    assert kw["shell"] is False and kw["timeout"] == 7 and kw["cwd"] == str(tmp_path)
    assert kw["stdin"] is subprocess.DEVNULL and kw["env"]["PYTHONUTF8"] == "1"

    def timeout_run(cmd, **kw):
        raise subprocess.TimeoutExpired(cmd, kw["timeout"])

    monkeypatch.setattr(forge.subprocess, "run", timeout_run)
    with pytest.raises(forge.ForgeUnavailable, match="7 с"):
        forge._run_forge(str(root), ["build"], tmp_path, 7)
    with pytest.raises(TypeError):
        forge._run_forge(str(root), ["notes", 5], tmp_path, 7)


# --- brief_notes ----------------------------------------------------------------------

def _notes_forge(monkeypatch, stdout: str, rc=0, stderr=b""):
    calls = []

    def run(forge_path, argv, cwd, timeout, **kw):
        calls.append(list(argv))
        return subprocess.CompletedProcess(argv, rc, stdout.encode("utf-8"), stderr)

    monkeypatch.setattr(forge, "_run_forge", run)
    return calls


def test_brief_notes_reads_file(tmp_path, monkeypatch):
    prof = tmp_path / "профили" / "vulkan-start"
    prof.mkdir(parents=True)
    (prof / "notes.md").write_bytes("\ufeff# заметки\nленты слева\n".encode("utf-8"))
    calls = _notes_forge(monkeypatch, f"profile:   {prof}\nnotes:     {prof / 'notes.md'}\n")
    out = _notes(None, "C:/forge")
    assert out == {"profile": "vulkan-start", "notes": "# заметки\nленты слева\n", "truncated": False}
    assert calls == [["notes"]]
    _notes("krastorio2", "C:/forge")
    assert calls[-1] == ["notes", "krastorio2"]


def test_brief_notes_truncates_on_char_boundary(tmp_path, monkeypatch):
    prof = tmp_path / "p"
    prof.mkdir()
    (prof / "notes.md").write_text("ж" * 100, encoding="utf-8")
    _notes_forge(monkeypatch, f"profile: {prof}\nnotes: {prof / 'notes.md'}\n")
    monkeypatch.setattr(forge, "MAX_NOTES_BYTES", 11)
    out = _notes("p", "C:/forge")
    assert out["truncated"] is True and out["notes"] == "ж" * 5


def test_brief_notes_missing_and_errors(tmp_path, monkeypatch):
    out = _notes(None, str(tmp_path / "nowhere"))
    assert out["notes"] == "" and "недоступен" in out["reason"]
    _notes_forge(monkeypatch, f"profile: {tmp_path}\nnotes: {tmp_path / 'notes.md'} (missing)\n")
    out = _notes("x", "C:/forge")
    assert out["notes"] == "" and "нет notes.md" in out["reason"]
    _notes_forge(monkeypatch, "", rc=1, stderr="no active profile".encode())
    assert "no active profile" in _notes(None, "C:/forge")["reason"]
    _notes_forge(monkeypatch, "notes: C:/somewhere/secrets.txt\n")
    assert "не понял" in _notes(None, "C:/forge")["reason"]
    out = _notes("-rf", "C:/forge")       # не бросает: сервер получает {reason}
    assert out["notes"] == "" and out["reason"]


# --- правки после ревью ---------------------------------------------------------------

def test_plan_uses_config_forge_home(tmp_path, fake):
    f = fake()
    cfg = _Cfg(tmp_path / "cfg-home", Path("C:/cfg-forge"), "vulkan-start", Path("C:/fhome"))
    a = mining()
    out = forge.plan("mining", a["resource"], None, None, config=cfg)
    assert "plan" in out, out
    assert all(c[3] > 0 for c in f.calls) and f.kw["forge_home"] == Path("C:/fhome")
    assert forge.load_plan(out["plan"], config=cfg) == BP


def test_plan_signature_is_the_contract():
    import inspect
    sig = inspect.signature(forge.plan)
    assert list(sig.parameters) == ["task", "resource", "patch", "options", "config"]
    assert sig.parameters["config"].kind is inspect.Parameter.KEYWORD_ONLY
    assert sig.parameters["config"].default is inspect.Parameter.empty
    assert list(inspect.signature(forge.load_plan).parameters) == ["plan_id", "config"]
    assert list(inspect.signature(forge.brief_notes).parameters) == ["config"]
    with pytest.raises(TypeError):
        forge.plan(mining())               # старый вид с args-словарём больше не принимается


def test_child_env_is_minimal(monkeypatch):
    monkeypatch.setenv("FP_RCON_PASSWORD_FILE", "secret.pw")
    monkeypatch.setenv("FP_HOME", "x")
    env = forge._child_env(Path("C:/fhome"))
    assert env["FACTORIO_FORGE_HOME"] == str(Path("C:/fhome")) and env["PYTHONUTF8"] == "1"
    assert not any(k.startswith("FP_") for k in env)


def test_plan_args_error_is_bad_args():
    err = forge.PlanArgsError("x")
    assert err.code == "bad_args" and isinstance(err, ValueError)


def test_active_profile_unreadable_name(tmp_path, monkeypatch):
    def run(forge_path, argv, cwd, timeout, **kw):
        return subprocess.CompletedProcess(argv, 0, "* мой сейв (from X) — ok\n".encode(), b"")
    monkeypatch.setattr(forge, "_run_forge", run)
    with pytest.raises(forge.ProfileNameUnreadable):
        forge.active_profile("C:/forge")
    out = _plan(mining(), tmp_path, "C:/forge", None)
    assert out["supported"] is False and "не разобрал" in out["reason"]
    assert "нет активного" not in out["reason"]


def test_stderr_reason_last_line_without_paths():
    raw = ("Traceback (most recent call last):\n"
           + r'  File "C:\Users\host\forge\cli.py", line 3, in main' + "\n"
           + r"FileNotFoundError: C:\Users\host\AppData\Roaming\factorio-forge\profiles\x missing" + "\n").encode()
    r = forge._stderr_reason(raw)
    assert r.startswith("FileNotFoundError:") and "Users" not in r and "<путь>" in r
    assert forge._stderr_reason(b"") == ""
    assert len(forge._stderr_reason(("e" * 1000).encode())) <= 200
    assert "/home/" not in forge._stderr_reason(b"error: /home/me/x.json not found")


def test_plan_work_dir_outside_fp_home(tmp_path, fake):
    f = fake()
    out = _plan(mining(), tmp_path, "C:/forge", None)
    assert "plan" in out
    work = f.calls[1][2]
    assert tmp_path not in work.parents and not work.exists()


def test_prune_removes_stale_leftovers(tmp_path):
    plans = tmp_path / "plans"
    plans.mkdir()
    old_work = plans / "work-p-0123456789abcdef-xyz"
    (old_work / "out").mkdir(parents=True)
    fresh_work = plans / "work-p-fedcba9876543210-abc"
    fresh_work.mkdir()
    old_tmp = plans / "p-0123456789abcdef.txt.tmp-aaaa"
    old_tmp.write_text("x")
    other = plans / "keep-me.txt"
    other.write_text("x")
    os.utime(old_work, (1000, 1000))
    os.utime(old_tmp, (1000, 1000))
    forge._prune(plans)
    left = sorted(p.name for p in plans.iterdir())
    assert left == sorted([fresh_work.name, other.name])


@pytest.mark.parametrize("drill, direction", [
    (d, k) for d in forge.DRILLS for k in ("north", "east", "south", "west")])
def test_layout_bbox_matches_anchor(drill, direction):
    req = forge.parse_args(mining(drill=drill, direction=direction))
    lay = forge.mining_layout(req)
    sizes = {n: d.size for n, d in forge.DRILLS.items()}
    xs = [e.x for e in lay.entities] + [e.x + sizes.get(e.name, 1) for e in lay.entities]
    ys = [e.y for e in lay.entities] + [e.y + sizes.get(e.name, 1) for e in lay.entities]
    cx, cy = (min(xs) + max(xs)) / 2, (min(ys) + max(ys)) / 2
    assert lay.anchor == {"x": cx, "y": cy}


def test_problem_reason_carries_finding_code(tmp_path, fake):
    fake(findings=[{"severity": "problem", "code": "pole-isolated", "summary": "pole is alone"}])
    out = _plan(mining(), tmp_path, "C:/forge", None)
    assert out["supported"] is False and "[pole-isolated]" in out["reason"]
