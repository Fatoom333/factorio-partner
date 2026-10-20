"""Build packages of the strategist, kept per save (docs/MCP.md «Пакеты стройки»).

A package is a named plan of ``plan`` steps with an anchor, a priority and 1..3 checks. Only the
strategist writes packages (``partner_ledger``); the server itself (orders.py) starts them on an idle
body and checks the result. The file lives next to the save's notes (savenotes.py) and outlives a
restart of the server:

    <FP_NOTES_DIR or <repo>/save-notes>/<save>/packages.json

    {"version": 1, "rev": N, "next": N, "packages": [...], "history": [...]}

``packages`` — open packages (``queued``, ``posting``, ``running``, ``pausing``, ``paused``,
``verifying``);
``history`` — the last finished ones (``verified``, ``unmet``, ``failed``, ``cancelled``), without
steps; ``notes`` — the strategist's last note on the work, one per helper; ``questions`` — his
questions to the owner per helper (``open`` / ``answered``), ``qnext`` numbers them; ``tasks`` — his
tasks to the pilots per helper (``open`` / closed by a report or a cancel), ``tnext`` numbers them;
``missing_tools`` — the last reports «no_tool» of the pilots (what a body could not do). Notes and
questions do not move ``rev``: ``rev`` guards the packages only. Every change goes through ``mutate``: a lock file, a fresh read of the file, the change, an
atomic write — two server processes (two sessions on one save) never lose each other's change.
The bridge of one process at a time drives the packages (``take_lease``).
"""
from __future__ import annotations

import json
import logging
import os
import time
from pathlib import Path
from typing import Any, Callable, Iterator
from contextlib import contextmanager

from . import savenotes
from .bridge import HELPER_RE
from .errors import PartnerError

log = logging.getLogger("factorio_partner.ledger")

FILE = "packages.json"
VERSION = 1
ACTIVE = ("queued", "posting", "running", "pausing", "paused")     # count towards ACTIVE_MAX
OPEN = ACTIVE + ("verifying",)
DONE = ("verified", "unmet", "failed", "cancelled")
ACTIVE_MAX = 2              # active packages per helper
HISTORY_MAX = 10
PRIORITY_RANK = {"now": 0, "next": 1, "later": 2}
LOCK_WAIT = 3.0             # s: how long a change waits for the lock of another process
LOCK_STALE = 10.0           # s: a lock file older than this was left by a dead process
LEASE_TTL = 60.0            # s: the bridge of one process drives the packages of a save (renewed per helper)
NOTE_MAX = 200              # characters of the strategist's note on the work
QUESTION_MAX = 200          # characters of a question to the owner
QUESTIONS_OPEN_MAX = 5      # open questions per helper
QUESTIONS_KEEP = 5          # answered questions kept per helper
ANSWER_SAID_MAX = 200       # characters of the owner's answer kept on the question
REMIND_AFTER = 10 * 60.0   # s: an open question unanswered this long is reminded once
# parts of the file that do not move rev
_SIDE = ("notes", "questions", "qnext", "thoughts", "rescale", "tasks", "tnext", "missing_tools")
TASK_TEXT_MAX = 600         # characters of a task of the strategist to a pilot
TASK_REPORT_MAX = 300       # characters of the pilot's report on a task
TASKS_OPEN_MAX = 5          # open tasks per body
TASKS_KEEP = 5              # closed tasks kept per body (partner_task list, partner_brief.work)
TASK_STATUSES = ("done", "failed", "no_tool")       # what the pilot reports
MISSING_TOOLS_MAX = 20      # the last «no_tool» reports kept for the owner
DUTY_RADIUS_MAX = 200       # the area of a duty: {center, radius ≤ 200}
DUTY_SLACK = 10             # a package farther than radius + this from a duty's centre waits

now = time.time             # wall clock of notes and questions: it outlives a restart (tests patch it)


def path_for(save: str) -> Path:
    return savenotes.root() / save / FILE


def _empty() -> dict:
    return {"version": VERSION, "rev": 0, "next": 1, "packages": [], "history": []}


def _well_formed(data: Any) -> bool:
    return (isinstance(data, dict) and isinstance(data.get("packages"), list)
            and isinstance(data.get("history"), list) and isinstance(data.get("rev"), int)
            and isinstance(data.get("next"), int))


def compact(p: dict) -> dict:
    """A package without its steps (lists, events, answers): ``steps_n`` instead."""
    out = {k: v for k, v in p.items() if k != "steps"}
    if isinstance(p.get("steps"), list):
        out["steps_n"] = len(p["steps"])
    return out


class Ledger:
    """The packages file of one save. Reads are cached by mtime; changes go through ``mutate``."""

    def __init__(self, save: str):
        self.save = save
        self.path = path_for(save)
        self._lock_path = self.path.with_name(FILE + ".lock")
        self._lease_path = self.path.with_name(FILE + ".lease")
        self._data: dict = _empty()
        self._stamp: tuple[int, int] | None = None

    # ------------------------------------------------------------------ reading
    def _read(self) -> dict:
        try:
            st = self.path.stat()
        except OSError:
            self._data, self._stamp = _empty(), None
            return self._data
        stamp = (st.st_mtime_ns, st.st_size)
        if stamp == self._stamp:
            return self._data
        try:
            data = json.loads(self.path.read_text(encoding="utf-8-sig"))
        except (OSError, ValueError):
            log.warning("packages file of save %s is not JSON; keeping the last good copy", self.save)
            return self._data
        if not _well_formed(data):
            log.warning("packages file of save %s has a bad shape; keeping the last good copy", self.save)
            return self._data
        self._data, self._stamp = data, stamp
        return data

    def data(self) -> dict:
        return self._read()

    def open_of(self, helper: str) -> list[dict]:
        return [p for p in self._read()["packages"]
                if isinstance(p, dict) and p.get("helper") == helper and p.get("status") in OPEN
                and isinstance(p.get("id"), str)]

    def get(self, helper: str, pid: str) -> dict | None:
        d = self._read()
        for p in d["packages"] + d["history"]:
            if p.get("id") == pid and p.get("helper") == helper:
                return p
        return None

    def helpers(self) -> set[str]:
        return {p["helper"] for p in self._read()["packages"]
                if isinstance(p, dict) and isinstance(p.get("helper"), str) and HELPER_RE.match(p["helper"])
                and p.get("status") in OPEN}

    # ------------------------------------------------------------------ changing
    @contextmanager
    def _locked(self) -> Iterator[None]:
        self.path.parent.mkdir(parents=True, exist_ok=True)
        deadline = time.monotonic() + LOCK_WAIT
        while True:
            try:
                fd = os.open(self._lock_path, os.O_CREAT | os.O_EXCL | os.O_WRONLY)
                os.write(fd, str(os.getpid()).encode("ascii"))
                os.close(fd)
                break
            except FileExistsError:
                try:
                    if time.time() - self._lock_path.stat().st_mtime > LOCK_STALE:
                        self._lock_path.unlink()
                        continue
                except OSError:
                    continue
                if time.monotonic() > deadline:
                    raise PartnerError("internal", "the packages file is locked by another server process") from None
                time.sleep(0.02)
        try:
            yield
        finally:
            try:
                self._lock_path.unlink()
            except OSError:
                pass

    def mutate(self, fn: Callable[[dict], Any]) -> Any:
        """Lock, read the file afresh, ``fn(data)``, write it back atomically if ``fn`` changed it
        (``rev`` grows by one per change). Returns what ``fn`` returned."""
        with self._locked():
            self._stamp = None
            data = self._read()
            data = json.loads(json.dumps(data))          # fn works on a copy: a raise changes nothing
            before = json.dumps(data, sort_keys=True)
            before_pk = _packages_part(data)
            out = fn(data)
            if json.dumps(data, sort_keys=True) != before:
                if _packages_part(data) != before_pk:
                    data["rev"] = int(data.get("rev", 0)) + 1
                _prune(data)
                tmp = self.path.with_name(FILE + f".{os.getpid()}.tmp")
                tmp.write_text(json.dumps(data, ensure_ascii=False, indent=1), encoding="utf-8")
                os.replace(tmp, self.path)
                self._stamp = None
                self._read()
            return out

    # ------------------------------------------------------------------ the bridge's lease
    def take_lease(self, owner: str, now: float | None = None) -> bool:
        """True if the bridge of ``owner`` may drive the packages of this save now: the lease is
        free, expired or already its own. The lease is renewed on every success. The read and the
        write go under the lock of the file, so two processes never both win a free lease."""
        try:
            with self._locked():
                now = time.time() if now is None else now
                try:
                    cur = json.loads(self._lease_path.read_text(encoding="utf-8"))
                except (OSError, ValueError):
                    cur = None
                if (isinstance(cur, dict) and cur.get("owner") != owner
                        and isinstance(cur.get("until"), (int, float)) and cur["until"] > now):
                    return False
                tmp = self._lease_path.with_name(FILE + f".lease.{os.getpid()}.tmp")
                tmp.write_text(json.dumps({"owner": owner, "until": now + LEASE_TTL}), encoding="utf-8")
                os.replace(tmp, self._lease_path)
        except (OSError, PartnerError):
            return False
        return True

def _packages_part(data: dict) -> str:
    return json.dumps({k: v for k, v in data.items() if k not in _SIDE and k != "rev"}, sort_keys=True)


def _prune(data: dict) -> None:
    """Finished packages leave ``packages`` for ``history`` (without steps); history keeps the last ones."""
    keep, done = [], []
    for p in data["packages"]:
        (done if p.get("status") in DONE else keep).append(p)
    data["packages"] = keep
    data["history"] = (data["history"] + [compact(p) for p in done])[-HISTORY_MAX:]


def find(data: dict, pid: str) -> dict | None:
    for p in data["packages"]:
        if p.get("id") == pid:
            return p
    return None


def add(data: dict, helper: str, clean: dict, tick: int | None, rev: int | None = None) -> dict:
    """Put a checked package (validate.check_package) into ``data`` as ``queued``."""
    if rev is not None and rev != data.get("rev"):
        raise PartnerError("bad_args", f"rev: the packages changed (rev {data.get('rev')}); read them again")
    active = [p for p in data["packages"] if p.get("helper") == helper and p.get("status") in ACTIVE]
    if len(active) >= ACTIVE_MAX:
        raise PartnerError("limit", f"at most {ACTIVE_MAX} active packages per helper; cancel one or "
                                    "wait for one to finish")
    n = int(data.get("next", 1))
    data["next"] = n + 1
    pkg = dict(clean, id=f"pk{n}", n=n, helper=helper, status="queued", created_tick=tick, from_step=1)
    data["packages"].append(pkg)
    return pkg


def next_up(pkgs: list[dict]) -> list[dict]:
    """Queued packages of one helper in the order they start: priority, then age."""
    q = [p for p in pkgs if p.get("status") == "queued"]
    return sorted(q, key=lambda p: (PRIORITY_RANK.get(p.get("priority"), 1), p.get("n", 0)))


# ---------------------------------------------------------------- the strategist's note and questions
def _side(data: dict, part: str) -> dict:
    v = data.get(part)
    if not isinstance(v, dict):
        v = data[part] = {}
    return v


def note_of(data: dict, helper: str) -> dict | None:
    v = data.get("notes")
    n = v.get(helper) if isinstance(v, dict) else None
    return n if isinstance(n, dict) and isinstance(n.get("text"), str) else None


def set_note(data: dict, helper: str, text: str, tick: int | None) -> dict:
    """The strategist's one last note on the work of a helper: a new one replaces the old."""
    n = {"text": text, "at": now(), "tick": tick}
    _side(data, "notes")[helper] = n
    return dict(n)


def thoughts_on(data: dict, helper: str, default: bool = False) -> bool:
    """Whether the strategist's thoughts are shown: the owner's own switch when he used it, else
    ``default`` (the mod's setting partner-thoughts)."""
    v = data.get("thoughts")
    got = v.get(helper) if isinstance(v, dict) else None
    return got if isinstance(got, bool) else default


def set_thoughts(data: dict, helper: str, on: bool) -> bool:
    """The owner's switch «show the strategist's thoughts» of a helper: kept as he set it (on or
    off), so that it wins over the default of the mod's settings."""
    _side(data, "thoughts")[helper] = bool(on)
    return on


def questions_of(data: dict, helper: str) -> list[dict]:
    v = data.get("questions")
    qs = v.get(helper) if isinstance(v, dict) else None
    return [q for q in qs if isinstance(q, dict) and isinstance(q.get("id"), str)] if isinstance(qs, list) else []


def open_questions(data: dict, helper: str) -> list[dict]:
    return [q for q in questions_of(data, helper) if q.get("status") == "open"]


def ask(data: dict, helper: str, text: str, tick: int | None, order: str | None = None,
        asker: str | None = None, perm: list[str] | None = None) -> dict:
    """A new open question to the owner (``q<N>``); at most QUESTIONS_OPEN_MAX open.
    ``order`` — the owner's order the question is about (the leave for a package of that order, or
    for calls of the pilot); ``asker`` — "pilot" when the pilot asks (the strategist by default);
    ``perm`` — the permission keys the question asks for (the «да» lifts only these)."""
    if len(open_questions(data, helper)) >= QUESTIONS_OPEN_MAX:
        raise PartnerError("limit", f"at most {QUESTIONS_OPEN_MAX} open questions per helper; wait for "
                                    "the owner's answers")
    n = int(data.get("qnext", 1)) if isinstance(data.get("qnext"), int) else 1
    data["qnext"] = n + 1
    q = {"id": f"q{n}", "text": text, "status": "open", "at": now(), "tick": tick}
    if order is not None:
        q["order"] = order
    if asker is not None:
        q["from"] = asker
    if perm:
        q["perm"] = list(perm)
    qs = _side(data, "questions").setdefault(helper, [])
    qs.append(q)
    _keep_questions(data, helper)
    return dict(q)


def answer(data: dict, helper: str, qid: str, order_id: str, said: str | None = None) -> dict:
    """Close an open question: the owner's answer came as the order ``order_id``; ``said`` — his own
    words (kept: a package's leave is refused when he said no)."""
    for q in questions_of(data, helper):
        if q["id"] == qid:
            if q.get("status") != "open":
                raise PartnerError("bad_args", f"answer_to: question {qid} is already {q.get('status')}")
            q.update(status="answered", answer=order_id, answered_at=now())
            if isinstance(said, str):
                q["said"] = said[:ANSWER_SAID_MAX]
            _keep_questions(data, helper)
            return dict(q)
    raise PartnerError("not_found", f"answer_to: no question {qid}")


def due_reminders(data: dict, helper: str, at: float | None = None) -> list[dict]:
    """Open questions unanswered REMIND_AFTER seconds and not reminded yet: they are marked reminded."""
    t = now() if at is None else at
    out = []
    for q in open_questions(data, helper):
        if not q.get("reminded") and isinstance(q.get("at"), (int, float)) and t - q["at"] >= REMIND_AFTER:
            q["reminded"] = t
            out.append(dict(q))
    return out


def _keep_questions(data: dict, helper: str) -> None:
    qs = _side(data, "questions").get(helper)
    if not isinstance(qs, list):
        return
    opened = [q for q in qs if isinstance(q, dict) and q.get("status") == "open"]
    closed = [q for q in qs if isinstance(q, dict) and q.get("status") != "open"][-QUESTIONS_KEEP:]
    keep = {id(q) for q in opened + closed}
    qs[:] = [q for q in qs if id(q) in keep]


# ---------------------------------------------------------------- the owner's leave for a package
_NO_START = ("нет", "неа", "no", "нельзя", "отказ", "стоп")
_NO_PHRASES = ("не надо", "не бери", "не трогай", "не смей", "не нужно", "не стоит", "нельзя", "запрещаю",
               "не разрешаю", "не забирай")


_YES_START = ("да", "ага", "ок", "ok", "okay", "yes", "можно", "бери", "забирай", "разрешаю", "конечно",
              "давай", "+", "угу")


def said_yes(text: Any) -> bool:
    """The owner's answer opens with an explicit «да» (allow-list): only that gives leave."""
    if not isinstance(text, str):
        return False
    t = " ".join(text.lower().replace("ё", "е").split())
    words = [w.strip(".,!?:;—-«»\"'()") for w in t.split()]
    words = [w for w in words if w]
    return bool(words) and words[0] in _YES_START


def said_no(text: Any) -> bool:
    """The owner's answer reads as a refusal («нет», «не бери», «нельзя»): no leave, whatever the
    strategist thinks it means."""
    if not isinstance(text, str):
        return False
    t = " ".join(text.lower().replace("ё", "е").split())
    words = [w.strip(".,!?:;—-«»\"'()") for w in t.split()]
    words = [w for w in words if w]
    if words and words[0] in _NO_START:
        return True
    return any(p in t for p in _NO_PHRASES)


def leave_problem(data: dict, scope: str, pkg: dict, order_tick: Any, at: float | None = None,
                  max_age: float | None = None) -> str | None:
    """Why the package may not take from the owner (None — it may): ``approved`` names a question of
    the strategist (of ``scope``) the owner answered, asked with the package's ``order``, and the
    answer opens with an explicit «да» (said_yes) and is no refusal; with ``max_age`` the answer is
    not older than that (seconds, at ``at`` or now)."""
    qid, oid = pkg.get("approved"), pkg.get("order")
    if not isinstance(qid, str) or not isinstance(oid, str):
        return "approved: a step takes from the owner — the package needs order and approved (q<N>)"
    q = next((x for x in questions_of(data, scope) if x["id"] == qid), None)
    if q is None:
        return f"approved: нет вопроса {qid} (partner_ledger list → questions)"
    if q.get("status") != "answered":
        return (f"approved: на вопрос {qid} хозяин ещё не ответил ({q.get('status')}); дождись ответа "
                "(поручение с answer_to)")
    if q.get("order") != oid:
        return (f"approved: вопрос {qid} не про поручение {oid}; разрешение даёт только вопрос с order: "
                f"partner_ledger{{action:\"ask\", order:\"{oid}\"}}")
    if said_no(q.get("said")) or not said_yes(q.get("said")):
        return (f"approved: ответ хозяина на {qid} — не явное «да» ({q.get('said')!r}): забирать нельзя; "
                "спроси заново")
    if max_age is not None:
        t = now() if at is None else at
        ans = q.get("answered_at")
        if not isinstance(ans, (int, float)) or t - ans > max_age:
            return (f"approved: ответ хозяина на {qid} старше {int(max_age // 60)} минут; "
                    "спроси заново")
    return None


PACKAGE_LEAVE_MAX_AGE = 60 * 60.0   # s: the owner's «да» gives leave to a package this long (put and run)
# a package's question asked without ``perm`` is about taking from the owner (its old meaning)
PACKAGE_LEAVE_DEFAULT = ("take_chests", "take_lines")


def leave_keys(q: dict | None, default: tuple[str, ...] = ()) -> list[str]:
    """The permission keys the owner's «да» to question ``q`` lifts (``perm`` of the question)."""
    v = q.get("perm") if isinstance(q, dict) else None
    if isinstance(v, list) and v and all(isinstance(k, str) for k in v):
        return list(v)
    return list(default)


def package_leave_keys(data: dict, scope: str, pkg: dict) -> list[str]:
    """The keys the leave of an approved package lifts: the question's ``perm``, else taking from
    the owner (PACKAGE_LEAVE_DEFAULT)."""
    qid = pkg.get("approved")
    q = next((x for x in questions_of(data, scope) if x["id"] == qid), None)
    return leave_keys(q, PACKAGE_LEAVE_DEFAULT)


def package_bind_problem(data: dict, scope: str, qid: str, pid: str | None) -> str | None:
    """One «да» is one use: a question that gave leave to single calls gives none to a package, and
    a question bound to an open package gives none to another one (a closed one frees it).
    ``pid`` — the package asking (None — a new one)."""
    q = next((x for x in questions_of(data, scope) if x["id"] == qid), None)
    if q is None:
        return f"approved: нет вопроса {qid} (partner_ledger list → questions)"
    used = q.get("uses")
    if isinstance(used, int) and not isinstance(used, bool) and used > 0:
        return (f"approved: разрешение по {qid} уже использовано для отдельных вызовов; для пакета "
                "спроси хозяина заново")
    bound = q.get("package")
    if isinstance(bound, str) and bound != pid:
        other = find(data, bound)
        if other is not None and other.get("status") in OPEN:
            return (f"approved: разрешение по {qid} уже отдано пакету {bound}; один ответ хозяина — "
                    "один пакет")
    if pid is not None and bound != pid:
        return f"approved: разрешение по {qid} не этого пакета ({pid})"
    return None


def bind_package(data: dict, scope: str, qid: str, pid: str) -> None:
    q = next((x for x in questions_of(data, scope) if x["id"] == qid), None)
    if q is not None:
        q["package"] = pid


def find_question(data: dict, qid: str, scopes) -> tuple[str, dict] | None:
    """The question ``qid`` in the first of ``scopes`` that holds it -> (scope, question)."""
    for sc in scopes:
        for q in questions_of(data, sc):
            if q["id"] == qid:
                return sc, q
    return None


APPROVED_MAX_AGE = 30 * 60.0   # s: the owner's «да» to a question gives leave to single calls this long
CALL_LEAVE_USES = 3            # calls one «да» gives leave to (act, plan, reflexes)


def call_leave_problem(data: dict, scopes, qid: str, oid: str, at: float | None = None) -> str | None:
    """Why a single call (act, plan, reflexes) may not go with the owner's leave (None — it may):
    the same check as a package's (``leave_problem``: a question asked with that ``order``, answered
    after it with an explicit «да»), in the caller's own ``scopes``, the answer is not older
    than APPROVED_MAX_AGE, the question names the permissions it asks for (``perm``) and its leave
    is not used up (CALL_LEAVE_USES calls)."""
    found = find_question(data, qid, scopes)
    if found is None:
        return f"approved: нет вопроса {qid} (partner_ledger list → questions)"
    scope, q = found
    why = leave_problem(data, scope, {"approved": qid, "order": oid}, None, at=at, max_age=APPROVED_MAX_AGE)
    if why is not None:
        return why
    if not leave_keys(q):
        return (f"approved: вопрос {qid} не называет, что разрешить; спроси заново с perm — ключи "
                "разрешений из partner_brief.perms.ask (например perm:[\"take_lines\"])")
    if q.get("package"):
        return (f"approved: разрешение по {qid} отдано пакету {q['package']}; для отдельного вызова "
                "спроси хозяина заново")
    used = q.get("uses")
    if isinstance(used, int) and not isinstance(used, bool) and used >= CALL_LEAVE_USES:
        return (f"approved: разрешение по {qid} уже использовано ({CALL_LEAVE_USES} вызова); "
                "спроси хозяина заново")
    return None


def take_call_leave(data: dict, scopes, qid: str, oid: str, at: float | None = None) -> list[str] | str:
    """Check the leave of one call (``call_leave_problem``) and use it once: -> the permission keys
    it lifts, or the reason it may not go (a string; nothing is changed then)."""
    why = call_leave_problem(data, scopes, qid, oid, at)
    if why is not None:
        return why
    _, q = find_question(data, qid, scopes)
    used = q.get("uses")
    q["uses"] = (used if isinstance(used, int) and not isinstance(used, bool) else 0) + 1
    return leave_keys(q)


# ---------------------------------------------------------------- the owner's request to restart
def rescale_of(data: dict) -> dict | None:
    """The owner's open request to restart the roles on ``n`` helpers (None — none)."""
    r = data.get("rescale")
    if isinstance(r, dict) and isinstance(r.get("n"), int) and not isinstance(r.get("n"), bool):
        return r
    return None


def set_rescale(data: dict, n: int, tasks: list, src: str, tick: int | None,
                seq: int | None = None, owner_said: str | None = None) -> dict:
    """A new request replaces the old one: the owner's last word counts."""
    r = {"n": n, "tasks": list(tasks), "from": src, "tick": tick, "at": now()}
    if seq is not None:
        r["seq"] = seq
    if isinstance(owner_said, str):
        r["owner_said"] = owner_said[:500]
    data["rescale"] = r
    return dict(r)


def clear_rescale(data: dict) -> dict | None:
    r = rescale_of(data)
    data.pop("rescale", None)
    return r


# ---------------------------------------------------------------- the strategist's tasks to a pilot
def tasks_of(data: dict, helper: str) -> list[dict]:
    v = data.get("tasks")
    ts = v.get(helper) if isinstance(v, dict) else None
    return [t for t in ts if isinstance(t, dict) and isinstance(t.get("id"), str)] if isinstance(ts, list) else []


def open_tasks(data: dict, helper: str) -> list[dict]:
    return [t for t in tasks_of(data, helper) if t.get("status") == "open"]


def _num(v: Any) -> bool:
    return isinstance(v, (int, float)) and not isinstance(v, bool)


def duties(data: dict, helper: str) -> list[dict]:
    """Open standing tasks (``duty`` with ``area``) of a body: they hold it in their area."""
    out = []
    for t in open_tasks(data, helper):
        a = t.get("area")
        c = a.get("center") if isinstance(a, dict) else None
        if (t.get("duty") is True and isinstance(c, dict) and _num(c.get("x")) and _num(c.get("y"))
                and _num(a.get("radius"))):
            out.append(t)
    return out


def task_helpers(data: dict) -> list[str]:
    v = data.get("tasks")
    return [h for h in v if isinstance(h, str) and HELPER_RE.match(h)] if isinstance(v, dict) else []


def give_task(data: dict, helper: str, text: str, duty: bool, area: dict | None,
              tick: int | None) -> dict:
    """A new open task of the strategist for the pilot of ``helper`` (``t<N>``); at most
    TASKS_OPEN_MAX open per body. The text is the strategist's: data for the pilot, never the
    owner's word."""
    if len(open_tasks(data, helper)) >= TASKS_OPEN_MAX:
        raise PartnerError("limit", f"at most {TASKS_OPEN_MAX} open tasks per helper; cancel one or wait "
                                    "for the pilot's report")
    n = int(data.get("tnext", 1)) if isinstance(data.get("tnext"), int) else 1
    data["tnext"] = n + 1
    t = {"id": f"t{n}", "from": "strategist", "text": text, "duty": bool(duty), "tick": tick,
         "status": "open", "at": now()}
    if area is not None:
        t["area"] = {"center": dict(area["center"]), "radius": area["radius"]}
    ts = _side(data, "tasks").setdefault(helper, [])
    ts.append(t)
    _keep_tasks(data, helper)
    return dict(t)


def find_task(data: dict, tid: str, helpers=None) -> tuple[str, dict] | None:
    """The task ``tid`` -> (its helper, the task); ``helpers`` — where to look (None — everywhere)."""
    for h in (task_helpers(data) if helpers is None else helpers):
        for t in tasks_of(data, h):
            if t["id"] == tid:
                return h, t
    return None


def cancel_task(data: dict, helper: str, tid: str, tick: int | None) -> dict:
    """Take an open task of ``helper`` off (the strategist: the need is over)."""
    found = find_task(data, tid, [helper])
    if found is None:
        raise PartnerError("not_found", f"id: no task {tid}")
    t = found[1]
    if t.get("status") != "open":
        raise PartnerError("bad_args", f"id: task {tid} is already {t.get('status')}")
    t.update(status="cancelled", closed_tick=tick, closed_at=now())
    _keep_tasks(data, helper)
    return dict(t)


def close_tasks(data: dict, helper: str, by: str, tick: int | None) -> list[dict]:
    """Close every open task of ``helper`` (``cancelled``, ``by``: ``owner`` — his «хватит» or his
    word to drop the task, ``reloaded`` — the save was loaded, ``helper_lost`` — the body is gone)."""
    out = []
    for t in open_tasks(data, helper):
        t.update(status="cancelled", by=by, closed_tick=tick, closed_at=now())
        out.append(dict(t))
    if out:
        _keep_tasks(data, helper)
    return out


def report_task(data: dict, helper: str, tid: str, status: str, text: str, tick: int | None) -> dict:
    """The pilot's report on an open task of its own body: it closes the task (a duty too — the
    need is over or the body cannot hold it). ``no_tool`` also goes to ``missing_tools``."""
    found = find_task(data, tid, [helper])
    if found is None:
        raise PartnerError("not_found", f"report.id: no task {tid} of this helper")
    t = found[1]
    if t.get("status") != "open":
        raise PartnerError("bad_args", f"report.id: task {tid} is already {t.get('status')}")
    t.update(status=status, report={"status": status, "text": text, "tick": tick}, closed_tick=tick,
             closed_at=now())
    if status == "no_tool":
        mt = data.get("missing_tools")
        if not isinstance(mt, list):
            mt = data["missing_tools"] = []
        mt.append({"text": text, "tick": tick, "task": tid, "helper": helper,
                   "task_text": str(t.get("text", ""))[:200]})
        del mt[:-MISSING_TOOLS_MAX]
    _keep_tasks(data, helper)
    return dict(t)


def missing_tools(data: dict, helper: str | None = None) -> list[dict]:
    """The last «no_tool» reports (of ``helper`` only, when given), oldest first."""
    mt = data.get("missing_tools")
    out = [m for m in mt if isinstance(m, dict)] if isinstance(mt, list) else []
    return [m for m in out if helper is None or m.get("helper") == helper]


def _keep_tasks(data: dict, helper: str) -> None:
    ts = _side(data, "tasks").get(helper)
    if not isinstance(ts, list):
        return
    opened = [t for t in ts if isinstance(t, dict) and t.get("status") == "open"]
    closed = [t for t in ts if isinstance(t, dict) and t.get("status") != "open"][-TASKS_KEEP:]
    keep = {id(t) for t in opened + closed}
    ts[:] = [t for t in ts if id(t) in keep]


def package_points(pkg: dict) -> list[dict]:
    """Where a package takes the body: its anchor and the points of its walk / approach steps."""
    pts = [pkg.get("anchor")]
    for s in pkg.get("steps") if isinstance(pkg.get("steps"), list) else []:
        if not isinstance(s, dict) or s.get("do") not in ("walk", "approach"):
            continue
        a = s.get("args") if isinstance(s.get("args"), dict) else {}
        pts.append(a.get("to"))
        tg = a.get("target")
        if isinstance(tg, dict):
            pts.append(tg.get("pos"))
    return [p for p in pts if isinstance(p, dict) and _num(p.get("x")) and _num(p.get("y"))]


def duty_blocking(data: dict, helper: str, pkg: dict) -> dict | None:
    """The open duty of ``helper`` the package would take the body away from (None — none): its
    anchor or a point of a walk / approach step lies farther than ``area.radius + DUTY_SLACK`` from
    the duty's centre."""
    pts = package_points(pkg)
    for t in duties(data, helper):
        c, r = t["area"]["center"], t["area"]["radius"]
        lim = (r + DUTY_SLACK) ** 2
        if any((p["x"] - c["x"]) ** 2 + (p["y"] - c["y"]) ** 2 > lim for p in pts):
            return t
    return None
