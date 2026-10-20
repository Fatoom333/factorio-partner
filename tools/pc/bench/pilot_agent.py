"""Запуск агента-пилота против стенда для сравнения моделей (docs/TESTING.md, tools/pc/run-pilot-bench.ps1).

Запуск (из tools/pc):
    python -m bench.pilot_agent run    --model sonnet --cwd <каталог> --mcp-config <mcp.json> --session <session.json>
                                       --helper h1 --out <каталог прогона> [--max-minutes 15] [--max-turns 120]
                                       [--watch-pid PID] [--stop-file ФАЙЛ] [--task-file ФАЙЛ] [--claude claude]
    python -m bench.pilot_agent record --manifest <manifest.json> --label sonnet-1 --model sonnet
                                       [--transcript ..] [--result ..] [--until ISO] [--usage-before N] [--usage-after N]

`run` запускает `claude -p --agent partner-pilot --model <модель>` с одним MCP-сервером (`--strict-mcp-config`) и
первым сообщением смены из файла сессии `agents/launch.py` плюс поручение замера (TASK сценария pilot_bench).
Сообщение уходит агенту через стандартный ввод: ключ помощника в нём, а список процессов его не показывает.
Смену останавливают: время (`--max-minutes`), число ходов модели в журнале (`--max-turns`), конец сценария
(`--watch-pid` — процесс run-live.ps1; пропал — стенд остановлен) или файл `--stop-file`. Журнал смены
(`<session-id>.jsonl` из ~/.claude/projects) копируется в каталог прогона как `transcript.jsonl`; в
`agent-run.json` — причина окончания и время конца (`ended_at`, для `until` в сводке).
Каталог `--cwd` должен содержать `.claude/agents/partner-pilot.md` и не должен быть репозиторием проекта:
так пилоту не достаются рабочие файлы проекта (CLAUDE.md, CLAUDE.local.md). Пользовательские настройки
машины (~/.claude: CLAUDE.md, хуки, плагины, скиллы) отключены (`--setting-sources project`,
`--disable-slash-commands`): замер одинаков на любой машине и не несёт чужих инструкций.
Секреты не печатаются; печатается только итог без текста сообщения.
"""
from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
import time
import uuid
from datetime import datetime, timezone
from typing import Any, Dict, List, Optional

AGENT = "partner-pilot"
ALLOWED_TOOLS = "mcp__partner__*"
SETTING_SOURCES = "project"
DEFAULT_MAX_MINUTES = 15.0
DEFAULT_MAX_TURNS = 120
POLL_S = 3.0
TASK_HEADER = ("Поручение хозяина для этого замера (голоса в замере нет, поручение передано напрямую; "
               "считай его словом хозяина, как событие `order`):")


def compose_prompt(session_prompt: str, task: str) -> str:
    """Первое сообщение смены: служебное от launch.py + поручение замера."""
    return session_prompt.rstrip() + "\n\n" + TASK_HEADER + "\n" + task.strip() + "\n"


def helper_prompt(session: Dict[str, Any], helper: str) -> str:
    for h in session.get("helpers") or []:
        if isinstance(h, dict) and h.get("id") == helper and isinstance(h.get("prompt"), str):
            return h["prompt"]
    raise ValueError("в файле сессии нет помощника %r" % helper)


def build_command(claude: str, model: str, mcp_config: str, session_id: str, effort: Optional[str] = None) -> List[str]:
    """Команда запуска; текст сообщения в неё не входит (идёт через stdin)."""
    cmd = [claude, "-p", "--agent", AGENT, "--model", model,
           "--mcp-config", mcp_config, "--strict-mcp-config",
           "--allowedTools", ALLOWED_TOOLS,
           "--permission-mode", "dontAsk",
           "--session-id", session_id,
           # only the run directory's .claude (the pilot's agent file): no user CLAUDE.md, hooks,
           # plugins or skills of the machine in the measured context
           "--setting-sources", SETTING_SOURCES, "--disable-slash-commands",
           "--output-format", "text"]
    if effort:
        cmd += ["--effort", effort]
    return cmd


def projects_root() -> str:
    return os.path.join(os.path.expanduser("~"), ".claude", "projects")


def find_transcript(session_id: str, root: Optional[str] = None) -> Optional[str]:
    root = root or projects_root()
    try:
        names = os.listdir(root)
    except OSError:
        return None
    for name in names:
        path = os.path.join(root, name, session_id + ".jsonl")
        if os.path.isfile(path):
            return path
    return None


def count_turns(path: Optional[str]) -> int:
    """Ответы модели в журнале (строки assistant, сгруппированные по message.id)."""
    if not path:
        return 0
    ids = set()
    anon = 0
    try:
        with open(path, "r", encoding="utf-8", errors="replace") as f:
            for raw in f:
                if '"assistant"' not in raw:
                    continue
                try:
                    row = json.loads(raw)
                except ValueError:
                    continue
                if not isinstance(row, dict) or row.get("type") != "assistant":
                    continue
                msg = row.get("message") if isinstance(row.get("message"), dict) else {}
                mid = msg.get("id")
                if isinstance(mid, str) and mid:
                    ids.add(mid)
                else:
                    anon += 1
    except OSError:
        return 0
    return len(ids) + anon


def pid_alive(pid: int) -> bool:
    if pid <= 0:
        return False
    if os.name == "nt":
        try:
            out = subprocess.run(["tasklist", "/FI", "PID eq %d" % pid, "/NH", "/FO", "CSV"],
                                 capture_output=True, text=True, timeout=20).stdout
        except (OSError, subprocess.SubprocessError):
            return True
        return ('"%d"' % pid) in out
    try:
        os.kill(pid, 0)
    except OSError:
        return False
    return True


def kill_tree(proc: "subprocess.Popen[Any]") -> None:
    if proc.poll() is not None:
        return
    if os.name == "nt":
        subprocess.run(["taskkill", "/PID", str(proc.pid), "/T", "/F"], capture_output=True, timeout=30)
    else:
        proc.kill()
    try:
        proc.wait(timeout=15)
    except subprocess.TimeoutExpired:
        pass


def _now_iso() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.%fZ")


def decide_stop(*, elapsed_s: float, max_s: float, turns: int, max_turns: int, watch_gone: bool,
                stop_file_exists: bool) -> Optional[str]:
    """Чистое решение «пора ли остановить смену» → причина | None."""
    if watch_gone:
        return "scenario_ended"
    if stop_file_exists:
        return "stop_file"
    if turns >= max_turns:
        return "max_turns"
    if elapsed_s >= max_s:
        return "timeout"
    return None


def run_agent(args: argparse.Namespace) -> Dict[str, Any]:
    with open(args.session, "r", encoding="utf-8-sig") as f:
        session = json.load(f)
    task = args.task
    if not task and getattr(args, "task_file", None):
        with open(args.task_file, "r", encoding="utf-8-sig") as f:
            task = f.read().strip()
    if not task:
        task = _scenario_task()
    prompt = compose_prompt(helper_prompt(session, args.helper), task)
    session_id = str(uuid.uuid4())
    os.makedirs(args.out, exist_ok=True)
    cmd = build_command(args.claude, args.model, args.mcp_config, session_id, args.effort)
    started = _now_iso()
    t0 = time.monotonic()
    out_log = open(os.path.join(args.out, "agent-stdout.txt"), "w", encoding="utf-8")
    proc = subprocess.Popen(cmd, cwd=args.cwd, stdin=subprocess.PIPE, stdout=out_log, stderr=subprocess.STDOUT,
                            text=True, encoding="utf-8")
    assert proc.stdin is not None
    proc.stdin.write(prompt)
    proc.stdin.close()
    reason = "agent_exit"
    transcript = None
    try:
        while proc.poll() is None:
            time.sleep(POLL_S)
            transcript = transcript or find_transcript(session_id)
            why = decide_stop(elapsed_s=time.monotonic() - t0, max_s=args.max_minutes * 60.0,
                              turns=count_turns(transcript), max_turns=args.max_turns,
                              watch_gone=bool(args.watch_pid) and not pid_alive(args.watch_pid),
                              stop_file_exists=bool(args.stop_file) and os.path.exists(args.stop_file))
            if why:
                reason = why
                break
    finally:
        ended_at = _now_iso()
        kill_tree(proc)
        out_log.close()
    transcript = find_transcript(session_id) or transcript
    info: Dict[str, Any] = {"model": args.model, "session_id": session_id, "reason": reason,
                            "exit_code": proc.returncode, "started_at": started, "ended_at": ended_at,
                            "wall_s": round(time.monotonic() - t0, 1), "turns_seen": count_turns(transcript),
                            "transcript": None}
    if transcript:
        dest = os.path.join(args.out, "transcript.jsonl")
        with open(transcript, "rb") as src, open(dest, "wb") as dst:
            dst.write(src.read())
        info["transcript"] = "transcript.jsonl"
    with open(os.path.join(args.out, "agent-run.json"), "w", encoding="utf-8") as f:
        json.dump(info, f, ensure_ascii=False, indent=1)
    return info


def _scenario_task() -> str:
    """Текст поручения — из сценария pilot_bench (единый источник)."""
    import importlib.util
    here = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    path = os.path.join(here, "scenarios", "pilot_bench.py")
    spec = importlib.util.spec_from_file_location("fp_scenario_pilot_bench", path)
    assert spec is not None and spec.loader is not None
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod.task_text()


def record(args: argparse.Namespace) -> Dict[str, Any]:
    """Добавить (или заменить по label) прогон в манифест сводки."""
    try:
        with open(args.manifest, "r", encoding="utf-8-sig") as f:
            data = json.load(f)
    except (OSError, ValueError):
        data = {"runs": []}
    runs = data.get("runs") if isinstance(data, dict) else data
    runs = [r for r in (runs or []) if isinstance(r, dict) and r.get("label") != args.label]
    entry: Dict[str, Any] = {"label": args.label, "model": args.model}
    for key in ("transcript", "result", "until"):
        v = getattr(args, key)
        if v:
            entry[key] = v
    for key in ("usage_before", "usage_after"):
        v = getattr(args, key)
        if v is not None:
            entry[key] = v
    runs.append(entry)
    with open(args.manifest, "w", encoding="utf-8") as f:
        json.dump({"runs": runs}, f, ensure_ascii=False, indent=1)
    return entry


def main(argv: Optional[List[str]] = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    sub = ap.add_subparsers(dest="cmd", required=True)
    r = sub.add_parser("run")
    r.add_argument("--model", required=True)
    r.add_argument("--cwd", required=True)
    r.add_argument("--mcp-config", required=True)
    r.add_argument("--session", required=True)
    r.add_argument("--helper", default="h1")
    r.add_argument("--out", required=True)
    r.add_argument("--task", help="текст поручения (по умолчанию — из сценария pilot_bench)")
    r.add_argument("--task-file", dest="task_file", help="файл с текстом поручения (когда сценарии рядом нет)")
    r.add_argument("--max-minutes", type=float, default=DEFAULT_MAX_MINUTES)
    r.add_argument("--max-turns", type=int, default=DEFAULT_MAX_TURNS)
    r.add_argument("--watch-pid", type=int, default=0)
    r.add_argument("--stop-file")
    r.add_argument("--claude", default="claude")
    r.add_argument("--effort")
    c = sub.add_parser("record")
    c.add_argument("--manifest", required=True)
    c.add_argument("--label", required=True)
    c.add_argument("--model", required=True)
    c.add_argument("--transcript")
    c.add_argument("--result")
    c.add_argument("--until")
    c.add_argument("--usage-before", dest="usage_before", type=float)
    c.add_argument("--usage-after", dest="usage_after", type=float)
    args = ap.parse_args(argv)
    try:
        if args.cmd == "run":
            info = run_agent(args)
        else:
            info = record(args)
    except (OSError, ValueError) as e:
        print("ошибка: %s" % (getattr(e, "strerror", None) or e), file=sys.stderr)
        return 2
    print(json.dumps(info, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    sys.exit(main())
