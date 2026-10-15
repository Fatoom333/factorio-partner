"""Клиент живых тестов на ПК (docs/TESTING.md §3).

Единственная точка отправки команд в игру из стенда:
- принимает только конверт протокола (dict, PROTOCOL.md §2) и сам добавляет префикс `/partner `;
- строки, начинающиеся с `/`, и вообще любые строки вместо конверта отвергает;
- `/quit` — только отдельной функцией `quit()`;
- `/c`, `/sc`, `/silent-command` отправить невозможно (проверка на нижнем уровне тоже стоит);
- RCON — только 127.0.0.1.

Только стандартная библиотека, совместимо с Python 3.9 (на ПК 3.9).

CLI (запускает tools/pc/remote/stand.ps1 на ПК):
    python live_client.py wait-ready --slot N --dir D:\\Temp\\fp-live-N [--timeout 240]
    python live_client.py run        --slot N --dir D:\\Temp\\fp-live-N --scenario NAME [--timeout 600]
    python live_client.py quit       --slot N --dir D:\\Temp\\fp-live-N
    python live_client.py check-log  --slot N --dir D:\\Temp\\fp-live-N   (после остановки сервера)
`check-log` читает вынесенный вычищенный журнал игры и проваливает сценарий, если в нём есть строка
под образец из его `log_must_not_match` (строка или список regex в результате сценария).
Пароль читается из <dir>/rcon.pw и никуда не пишется (ни в журнал, ни в results).
"""
from __future__ import annotations

import argparse
import importlib.util
import itertools
import json
import os
import re
import socket
import struct
import sys
import threading
import time
import traceback
from typing import Any, Callable, Dict, Optional

PROTO_VERSION = 1
RCON_HOST = "127.0.0.1"
RCON_BASE_PORT = 27100
GAME_BASE_PORT = 34200
SLOTS = range(0, 10)
PREFIX = "/partner "
QUIT_COMMAND = "/quit"

# Предел запроса по контракту (PROTOCOL §2). Замер (сценарий e_rcon_maxlen) может поднять его
# через client.max_request_bytes, но не выше HARD_REQUEST_CAP (проверяет сеттер).
DEFAULT_MAX_REQUEST_BYTES = 8 * 1024
HARD_REQUEST_CAP = 1024 * 1024
# Ответ ≤ 200 000 байт по контракту (PROTOCOL §2); пакет больше 1 МБ — кривой размер, не читаем.
MAX_RESPONSE_BYTES = 1024 * 1024

ID_RE = re.compile(r"^[A-Za-z0-9_.:-]{1,40}$")
OP_RE = re.compile(r"^[a-z][a-z0-9_]{0,39}$")
HELPER_RE = re.compile(r"^[a-z0-9_-]{1,16}$")
SCENARIO_RE = re.compile(r"^[a-z0-9_]{1,64}$")
FORBIDDEN_RE = re.compile(r"^\s*/(c|sc|silent-command|command|measured-command)(\s|$)", re.IGNORECASE)

# Source RCON
_AUTH = 3
_AUTH_RESPONSE = 2
_EXECCOMMAND = 2
_RESPONSE_VALUE = 0

LOG_SNIPPET = 300


class LiveClientError(Exception):
    """kind: refused (стенд не пустил), transport (обрыв/таймаут), auth, protocol (кривой ответ)."""

    def __init__(self, kind: str, message: str):
        super().__init__(f"{kind}: {message}")
        self.kind = kind
        self.message = message


def rcon_port(slot: int) -> int:
    _check_slot(slot)
    return RCON_BASE_PORT + slot


def game_port(slot: int) -> int:
    _check_slot(slot)
    return GAME_BASE_PORT + slot


def _check_slot(slot: Any) -> None:
    if not isinstance(slot, int) or isinstance(slot, bool) or slot not in SLOTS:
        raise LiveClientError("refused", f"слот должен быть 0..9, а не {slot!r}")


def _snip(text: str, limit: int = LOG_SNIPPET) -> str:
    text = text.replace("\r", "\\r").replace("\n", "\\n")
    if len(text) > limit:
        return f"{text[:limit]}…(+{len(text) - limit})"
    return text


def encode_packet(pid: int, ptype: int, body: bytes) -> bytes:
    payload = struct.pack("<ii", pid, ptype) + body + b"\x00\x00"
    return struct.pack("<i", len(payload)) + payload


def validate_envelope(envelope: Any) -> None:
    """Проверка конверта до отправки (PROTOCOL §2). Строки и всё, кроме dict, — отказ."""
    if isinstance(envelope, (str, bytes, bytearray)):
        raise LiveClientError("refused", "стенд принимает только конверт (dict), не строку команды")
    if not isinstance(envelope, dict):
        raise LiveClientError("refused", f"конверт должен быть dict, а не {type(envelope).__name__}")
    allowed = {"v", "id", "op", "helper", "args"}
    extra = set(envelope) - allowed
    if extra:
        raise LiveClientError("refused", f"лишние поля конверта: {sorted(extra)}")
    v = envelope.get("v")
    if not isinstance(v, int) or isinstance(v, bool):
        raise LiveClientError("refused", "поле v должно быть целым")
    rid = envelope.get("id")
    if not isinstance(rid, str) or not ID_RE.match(rid):
        raise LiveClientError("refused", "поле id: 1–40 символов [A-Za-z0-9_.:-]")
    op = envelope.get("op")
    if not isinstance(op, str) or not OP_RE.match(op):
        raise LiveClientError("refused", "поле op: [a-z][a-z0-9_]{0,39}")
    if "helper" in envelope:
        helper = envelope["helper"]
        if not isinstance(helper, str) or not HELPER_RE.match(helper):
            raise LiveClientError("refused", "поле helper: ^[a-z0-9_-]{1,16}$")
    if "args" in envelope and not isinstance(envelope["args"], dict):
        raise LiveClientError("refused", "поле args должно быть объектом")


def build_command(envelope: Dict[str, Any]) -> str:
    validate_envelope(envelope)
    text = json.dumps(envelope, ensure_ascii=False, separators=(",", ":"), allow_nan=False)
    # json.dumps экранирует переводы строк внутри строк; сырых \n в команде быть не может.
    assert "\n" not in text and "\r" not in text
    return PREFIX + text


class LiveClient:
    """RCON-клиент стенда. Одна команда за раз, ответ сверяется по id пакета и id конверта."""

    def __init__(self, port: int, password: str, host: str = RCON_HOST, timeout: float = 10.0,
                 id_prefix: str = "e", log_path: Optional[str] = None):
        if host != RCON_HOST:
            raise LiveClientError("refused", "RCON только на 127.0.0.1")
        if not isinstance(port, int) or not (1 <= port <= 65535):
            raise LiveClientError("refused", f"плохой порт {port!r}")
        if not isinstance(password, str) or not password:
            raise LiveClientError("refused", "пустой пароль RCON")
        if not re.match(r"^[A-Za-z0-9_.-]{1,16}$", id_prefix):
            raise LiveClientError("refused", "плохой id_prefix")
        self.host = host
        self.port = port
        self.timeout = float(timeout)
        self._max_request_bytes = DEFAULT_MAX_REQUEST_BYTES
        self._password = password
        self._sock: Optional[socket.socket] = None
        self._lock = threading.Lock()
        self._pid = itertools.count(1)
        self._rid = itertools.count(1)
        self._id_prefix = id_prefix
        self._run_tag = f"{int(time.time()) % 100000:05d}"
        self._log_path = log_path
        self.deadline: Optional[float] = None  # монотонное время конца сценария (ставит run)
        self.sent = 0

    def __repr__(self) -> str:  # без пароля
        return f"LiveClient({self.host}:{self.port})"

    @property
    def max_request_bytes(self) -> int:
        return self._max_request_bytes

    @max_request_bytes.setter
    def max_request_bytes(self, value: int) -> None:
        if not isinstance(value, int) or isinstance(value, bool) or not (1 <= value <= HARD_REQUEST_CAP):
            raise LiveClientError("refused", f"max_request_bytes: 1..{HARD_REQUEST_CAP}, а не {value!r}")
        self._max_request_bytes = value

    # ---------- соединение ----------
    def connect(self) -> None:
        self.close()
        try:
            sock = socket.create_connection((self.host, self.port), timeout=self.timeout)
        except OSError as e:
            raise LiveClientError("transport", f"нет соединения с {self.host}:{self.port}: {e}") from None
        sock.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
        self._sock = sock
        try:
            self._auth()
        except Exception:
            self.close()
            raise
        self._log("connect", f"{self.host}:{self.port}")

    def reconnect(self) -> None:
        self.connect()

    def close(self) -> None:
        if self._sock is not None:
            try:
                self._sock.close()
            except OSError:
                pass
            self._sock = None

    @property
    def connected(self) -> bool:
        return self._sock is not None

    def __enter__(self) -> "LiveClient":
        self.connect()
        return self

    def __exit__(self, *exc: Any) -> None:
        self.close()

    def _auth(self) -> None:
        pid = next(self._pid)
        self._write(encode_packet(pid, _AUTH, self._password.encode("utf-8")))
        end = time.monotonic() + self.timeout
        while True:
            rpid, rtype, _ = self._read_packet(end)
            if rtype == _AUTH_RESPONSE:
                if rpid == -1:
                    raise LiveClientError("auth", "RCON отверг пароль")
                if rpid != pid:
                    raise LiveClientError("protocol", f"ответ авторизации с чужим id {rpid}")
                return
            # Некоторые серверы шлют пустой RESPONSE_VALUE перед AUTH_RESPONSE — пропускаем.

    # ---------- низкий уровень ----------
    def _write(self, data: bytes) -> None:
        if self._sock is None:
            raise LiveClientError("transport", "нет соединения")
        try:
            self._sock.settimeout(self.timeout)
            self._sock.sendall(data)
        except OSError as e:
            self.close()
            raise LiveClientError("transport", f"отправка не удалась: {e}") from None

    def _recv_exact(self, n: int, end: float) -> bytes:
        buf = bytearray()
        while len(buf) < n:
            left = end - time.monotonic()
            if left <= 0:
                self.close()
                raise LiveClientError("transport", "таймаут ответа")
            if self._sock is None:
                raise LiveClientError("transport", "нет соединения")
            try:
                self._sock.settimeout(left)
                chunk = self._sock.recv(min(n - len(buf), 1 << 16))
            except socket.timeout:
                self.close()
                raise LiveClientError("transport", "таймаут ответа") from None
            except OSError as e:
                self.close()
                raise LiveClientError("transport", f"чтение не удалось: {e}") from None
            if not chunk:
                self.close()
                raise LiveClientError("transport", "сервер закрыл соединение")
            buf += chunk
        return bytes(buf)

    def _read_packet(self, end: float):
        (size,) = struct.unpack("<i", self._recv_exact(4, end))
        if size < 10 or size > MAX_RESPONSE_BYTES:
            self.close()
            raise LiveClientError("protocol", f"плохой размер пакета {size}")
        data = self._recv_exact(size, end)
        pid, ptype = struct.unpack("<ii", data[:8])
        body = data[8:-2]
        return pid, ptype, body

    def _send_raw(self, command: str, timeout: Optional[float] = None) -> str:
        """Отправить готовую строку. Пропускает только `/partner {…}` и `/quit`."""
        if command != QUIT_COMMAND:
            if not command.startswith(PREFIX + "{") or FORBIDDEN_RE.match(command):
                raise LiveClientError("refused", "стенд шлёт только /partner <JSON> и /quit")
        body = command.encode("utf-8")
        if command != QUIT_COMMAND and len(body) - len(PREFIX) > self.max_request_bytes:
            raise LiveClientError(
                "refused", f"запрос {len(body) - len(PREFIX)} байт больше предела {self.max_request_bytes}")
        with self._lock:
            if self._sock is None:
                self.connect()
            pid = next(self._pid)
            self._write(encode_packet(pid, _EXECCOMMAND, body))
            self.sent += 1
            end = time.monotonic() + (self.timeout if timeout is None else float(timeout))
            while True:
                rpid, rtype, rbody = self._read_packet(end)
                # Ответ — ровно один пакет: Factorio 2.0.77 не дробит ответ (300 КБ пришли одним
                # пакетом, замер 06.10, PROTOCOL §2). Если начнёт дробить, как Source RCON по 4096,
                # здесь вернётся первый кусок и _parse_reply скажет «ответ не JSON». Живая проверка —
                # e_big в сценарии e_rcon_maxlen.
                if rpid == pid and rtype == _RESPONSE_VALUE:
                    # Factorio может обрезать кириллицу посреди символа — не падаем.
                    return rbody.decode("utf-8", errors="replace")
                # Чужой/запоздавший ответ (после таймаута прошлой команды) — пропускаем.
                self._log("skip", f"pid={rpid} type={rtype} {_snip(rbody.decode('utf-8', 'replace'))}")

    # ---------- конверты ----------
    def next_id(self) -> str:
        return f"{self._id_prefix}-{self._run_tag}-{next(self._rid):06d}"

    def make_envelope(self, op: str, args: Optional[Dict[str, Any]] = None, helper: Optional[str] = None,
                      rid: Optional[str] = None) -> Dict[str, Any]:
        env: Dict[str, Any] = {"v": PROTO_VERSION, "id": rid or self.next_id(), "op": op,
                               "args": {} if args is None else args}
        if helper is not None:
            env["helper"] = helper
        return env

    def send(self, envelope: Dict[str, Any], timeout: Optional[float] = None) -> Dict[str, Any]:
        """Отправить конверт, вернуть разобранный ответ (dict). ok=false — не исключение."""
        command = build_command(envelope)
        self._log(">>", f"id={envelope['id']} op={envelope['op']} bytes={len(command.encode('utf-8')) - len(PREFIX)} "
                        f"{_snip(command[len(PREFIX):])}")
        text = self._send_raw(command, timeout=timeout)
        self._log("<<", f"id={envelope['id']} {_snip(text)}")
        return self._parse_reply(envelope, text)

    @staticmethod
    def _parse_reply(envelope: Dict[str, Any], text: str) -> Dict[str, Any]:
        stripped = text.strip()
        if not stripped:
            raise LiveClientError("protocol", "пустой ответ (мод ничего не напечатал или /partner не зарегистрирован)")
        try:
            reply = json.loads(stripped)
        except ValueError:
            raise LiveClientError("protocol", f"ответ не JSON: {_snip(stripped, 200)}") from None
        if not isinstance(reply, dict):
            raise LiveClientError("protocol", "ответ не объект")
        rid = reply.get("id")
        # bad_request на нечитаемый JSON может прийти без id — это не «чужой ответ».
        if rid is not None and rid != envelope["id"]:
            raise LiveClientError("protocol", f"ответ на чужой id {rid!r}, ждали {envelope['id']!r}")
        if not isinstance(reply.get("ok"), bool):
            raise LiveClientError("protocol", "в ответе нет ok")
        return reply

    def call(self, op: str, args: Optional[Dict[str, Any]] = None, helper: Optional[str] = None,
             timeout: Optional[float] = None, rid: Optional[str] = None) -> Dict[str, Any]:
        return self.send(self.make_envelope(op, args, helper, rid), timeout=timeout)

    def call_ok(self, op: str, args: Optional[Dict[str, Any]] = None, helper: Optional[str] = None,
                timeout: Optional[float] = None) -> Any:
        reply = self.call(op, args, helper, timeout)
        if not reply["ok"]:
            err = reply.get("error") or {}
            raise LiveClientError("protocol", f"{op}: {err.get('code')} {err.get('text', '')}")
        return reply.get("data")

    def quit(self) -> str:
        """Остановить сервер (`/quit`). Единственный путь отправить не-/partner команду."""
        self._log(">>", "quit")
        try:
            return self._send_raw(QUIT_COMMAND, timeout=5.0)
        except LiveClientError as e:
            # Сервер часто закрывает соединение, не ответив: это нормально для /quit.
            if e.kind == "transport":
                return ""
            raise
        finally:
            self.close()

    # ---------- утилиты для сценариев ----------
    def time_left(self) -> float:
        if self.deadline is None:
            return float("inf")
        return self.deadline - time.monotonic()

    def sleep(self, seconds: float) -> None:
        seconds = max(0.0, min(float(seconds), self.time_left()))
        time.sleep(seconds)

    def poll(self, fn: Callable[[], Any], timeout: float, interval: float = 1.0) -> Any:
        """Вызывать fn, пока не вернёт истинное значение или не выйдет время. Возвращает последнее."""
        end = time.monotonic() + min(float(timeout), self.time_left())
        while True:
            value = fn()
            if value or time.monotonic() >= end:
                return value
            time.sleep(min(interval, max(0.0, end - time.monotonic())))

    def _log(self, tag: str, text: str) -> None:
        if not self._log_path:
            return
        try:
            with open(self._log_path, "a", encoding="utf-8") as f:
                f.write(f"{time.strftime('%H:%M:%S')} {tag} {text}\n")
        except OSError:
            pass


# ---------- CLI ----------
def read_password(slot_dir: str) -> str:
    path = os.path.join(slot_dir, "rcon.pw")
    try:
        with open(path, "r", encoding="utf-8-sig") as f:
            pw = f.read().strip()
    except OSError as e:
        raise LiveClientError("auth", f"не прочитать файл пароля: {e.strerror}") from None
    if not pw:
        raise LiveClientError("auth", "файл пароля пуст")
    return pw


def scenarios_dir() -> str:
    return os.path.join(os.path.dirname(os.path.abspath(__file__)), "scenarios")


def load_scenario(name: str, directory: Optional[str] = None):
    if not isinstance(name, str) or not SCENARIO_RE.match(name):
        raise LiveClientError("refused", "имя сценария: [a-z0-9_]{1,64}")
    directory = directory or scenarios_dir()
    path = os.path.join(directory, name + ".py")
    if not os.path.isfile(path):
        raise LiveClientError("refused", f"нет сценария {name}")
    spec = importlib.util.spec_from_file_location(f"fp_scenario_{name}", path)
    module = importlib.util.module_from_spec(spec)
    assert spec.loader is not None
    spec.loader.exec_module(module)
    if not callable(getattr(module, "run", None)):
        raise LiveClientError("refused", f"в сценарии {name} нет run(client)")
    return module


def _write_json(path: str, data: Dict[str, Any]) -> None:
    tmp = path + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(data, f, ensure_ascii=False, indent=2)
    os.replace(tmp, path)


def _scrub(obj: Any, secret: Any) -> Any:
    """Пароль (и другие секреты запуска) не должны попасть в results ни при каких условиях.

    secret — строка или набор строк; пустые пропускаются."""
    secrets_ = [secret] if isinstance(secret, str) else list(secret or ())
    secrets_ = [s for s in secrets_ if isinstance(s, str) and s]
    if not secrets_:
        return obj

    def clean(v: Any) -> Any:
        if isinstance(v, str):
            for s in secrets_:
                v = v.replace(s, "<private>")
            return v
        if isinstance(v, dict):
            return {clean(str(k)): clean(x) for k, x in v.items()}
        if isinstance(v, (list, tuple)):
            return [clean(x) for x in v]
        return v

    return clean(obj)


# ---------- журнал игры: log_must_not_match (TESTING.md §3) ----------
LOG_PATTERN_MAX = 500       # длина одного образца
LOG_PATTERNS_MAX = 8        # образцов в сценарии
LOG_LINE_MAX = 4000         # длиннее строку журнала режем (образцы — про короткие строки мода)
LOG_MATCHES_KEPT = 5        # сколько совпавших строк кладём в results
LOG_BYTES_MAX = 64 * 1024 * 1024


def log_patterns(value: Any) -> list:
    """Образцы из `result["log_must_not_match"]`: строка или список строк → скомпилированные regex.

    Нет поля / None → []. Кривая форма или regex — LiveClientError("refused", …): сценарий, который
    просил проверку журнала, без неё зелёным не бывает."""
    if value is None:
        return []
    items = [value] if isinstance(value, str) else value
    if not isinstance(items, (list, tuple)) or not items or len(items) > LOG_PATTERNS_MAX:
        raise LiveClientError("refused", f"log_must_not_match: строка или список 1..{LOG_PATTERNS_MAX} строк")
    out = []
    for p in items:
        if not isinstance(p, str) or not p or len(p) > LOG_PATTERN_MAX:
            raise LiveClientError("refused", f"log_must_not_match: образец — непустая строка до {LOG_PATTERN_MAX} символов")
        try:
            out.append(re.compile(p))
        except re.error as e:
            raise LiveClientError("refused", f"log_must_not_match: плохой regex ({e})") from None
    return out


def log_matches(text: str, patterns: list, keep: int = LOG_MATCHES_KEPT) -> Dict[str, Any]:
    """Строки журнала, подходящие под любой образец. → {"count": всего, "lines": [первые keep]}."""
    count = 0
    lines = []
    for no, line in enumerate(text.splitlines(), 1):
        line = line[:LOG_LINE_MAX]
        for rx in patterns:
            if rx.search(line):
                count += 1
                if len(lines) < keep:
                    lines.append({"line": no, "pattern": rx.pattern, "text": _snip(line)})
                break
    return {"count": count, "lines": lines}


def check_log(slot: int, slot_dir: str) -> int:
    """Проверить вынесенный журнал игры по `log_must_not_match` из results сценария.

    Зовётся стендом ПОСЛЕ остановки сервера: журнал уже лежит вычищенным в out/factorio-<slot>.log.
    Нашлась строка, нет журнала или образец кривой → в results `ok=false` и причина в `log_check`.
    Код: 0 — проверять нечего или чисто, 1 — сценарий провален журналом, 2 — нет results."""
    _check_slot(slot)
    out_dir = os.path.join(slot_dir, "out")
    results_path = os.path.join(out_dir, f"results-{slot}.json")
    log_file = os.path.join(out_dir, f"factorio-{slot}.log")
    try:
        with open(results_path, "r", encoding="utf-8") as f:
            result = json.load(f)
    except (OSError, ValueError) as e:
        print(f"check-log: нет results ({type(e).__name__})", file=sys.stderr)
        return 2
    if not isinstance(result, dict) or result.get("log_must_not_match") is None:
        return 0
    check: Dict[str, Any] = {"ok": False, "patterns": result.get("log_must_not_match")}
    try:
        patterns = log_patterns(result.get("log_must_not_match"))
        try:
            if os.path.getsize(log_file) > LOG_BYTES_MAX:
                raise LiveClientError("refused", f"журнал игры больше {LOG_BYTES_MAX} байт")
            with open(log_file, "r", encoding="utf-8-sig", errors="replace") as f:
                text = f.read()
        except OSError:
            raise LiveClientError("refused", "журнал игры не вынесен — проверить log_must_not_match нечем") from None
        found = log_matches(text, patterns)
        check.update(matches=found["count"], lines=found["lines"], ok=found["count"] == 0)
        if found["count"]:
            check["text"] = f"в журнале игры {found['count']} строк(и) под запретный образец"
    except LiveClientError as e:
        check["text"] = e.message
    result["log_check"] = check
    if not check["ok"]:
        result["ok"] = False
        result.setdefault("reasons", [])
        if isinstance(result["reasons"], list):
            result["reasons"].append("журнал игры: " + str(check.get("text")))
    secrets_: list = []
    try:
        secrets_.append(read_password(slot_dir))
    except LiveClientError:
        pass
    _write_json(results_path, _scrub(result, secrets_))
    print(json.dumps({"log_check": check["ok"], "matches": check.get("matches"), "text": check.get("text")},
                     ensure_ascii=False))
    return 0 if check["ok"] else 1


def run_scenario(slot: int, slot_dir: str, scenario: str, timeout: float,
                 scenario_directory: Optional[str] = None, rcon_timeout: float = 10.0,
                 wrap: Optional[Callable[..., Any]] = None) -> Dict[str, Any]:
    """Запустить сценарий и записать <dir>/out/results-<slot>.json. Возвращает результат.

    wrap(client, module, secrets) -> объект для `module.run(...)` — так server_client.py подменяет
    клиента на обёртку над настоящим сервером; в список secrets она дописывает свои секреты (ключ
    помощника), чтобы они не попали в results. У обёртки может быть `close()`."""
    _check_slot(slot)
    out_dir = os.path.join(slot_dir, "out")
    os.makedirs(out_dir, exist_ok=True)
    results_path = os.path.join(out_dir, f"results-{slot}.json")
    log_path = os.path.join(out_dir, f"live-{slot}.log")
    started = time.time()
    meta = {"slot": slot, "scenario": scenario, "started": time.strftime("%Y-%m-%dT%H:%M:%S", time.localtime(started))}
    password = ""
    secrets_: list = []
    done = threading.Event()
    write_lock = threading.Lock()

    def finish(result: Dict[str, Any]) -> Dict[str, Any]:
        with write_lock:
            if done.is_set():
                return result
            result = dict(result)
            result.setdefault("ok", False)
            result["meta"] = dict(meta, duration_s=round(time.time() - started, 2))
            result = _scrub(result, [password] + secrets_)
            _write_json(results_path, result)
            done.set()
            return result

    def on_timeout() -> None:
        finish({"ok": False, "error": {"kind": "timeout", "text": f"сценарий дольше {timeout:.0f} с"}})
        os._exit(3)

    watchdog = threading.Timer(timeout + 5.0, on_timeout)
    watchdog.daemon = True
    watchdog.start()
    client: Optional[LiveClient] = None
    wrapped: Any = None
    try:
        module = load_scenario(scenario, scenario_directory)
        password = read_password(slot_dir)
        client = LiveClient(rcon_port(slot), password, timeout=rcon_timeout, id_prefix=f"e{slot}", log_path=log_path)
        client.deadline = time.monotonic() + timeout
        client.connect()
        wrapped = wrap(client, module, secrets_) if wrap is not None else None
        result = module.run(wrapped if wrapped is not None else client)
        if not isinstance(result, dict):
            result = {"ok": False, "error": {"kind": "scenario", "text": "run() вернул не dict"}}
        result.setdefault("requests", client.sent)
        return finish(result)
    except LiveClientError as e:
        return finish({"ok": False, "error": {"kind": e.kind, "text": e.message}})
    except Exception as e:  # сценарий упал — отчёт всё равно пишем
        tb = traceback.format_exc(limit=6)
        return finish({"ok": False, "error": {"kind": "exception", "text": f"{type(e).__name__}: {e}", "trace": tb}})
    finally:
        watchdog.cancel()
        closer = getattr(wrapped, "close", None)
        if callable(closer):
            try:
                closer()
            except Exception:  # закрытие обёртки не должно портить итог
                pass
        if client is not None:
            client.close()


def wait_ready(slot: int, slot_dir: str, timeout: float) -> bool:
    password = read_password(slot_dir)
    end = time.monotonic() + timeout
    last = ""
    while time.monotonic() < end:
        client = LiveClient(rcon_port(slot), password, timeout=5.0)
        try:
            client.connect()
            return True
        except LiveClientError as e:
            if e.kind == "auth":
                print(f"wait-ready: {e.message}", file=sys.stderr)
                return False
            last = e.message
        finally:
            client.close()
        time.sleep(2.0)
    print(f"wait-ready: RCON не ответил за {timeout:.0f} с ({last})", file=sys.stderr)
    return False


def send_quit(slot: int, slot_dir: str) -> bool:
    client = LiveClient(rcon_port(slot), read_password(slot_dir), timeout=5.0)
    try:
        client.connect()
        client.quit()
        return True
    except LiveClientError as e:
        print(f"quit: {e.kind}: {e.message}", file=sys.stderr)
        return False
    finally:
        client.close()


def main(argv: Optional[list] = None) -> int:
    parser = argparse.ArgumentParser(description="Клиент живых тестов factorio-partner")
    sub = parser.add_subparsers(dest="cmd", required=True)
    for name in ("run", "wait-ready", "quit", "check-log"):
        p = sub.add_parser(name)
        p.add_argument("--slot", type=int, required=True)
        p.add_argument("--dir", required=True)
        if name == "run":
            p.add_argument("--scenario", required=True)
            p.add_argument("--timeout", type=float, default=600.0)
        if name == "wait-ready":
            p.add_argument("--timeout", type=float, default=240.0)
    for stream in (sys.stdout, sys.stderr):
        try:
            stream.reconfigure(encoding="utf-8", errors="replace")  # кириллица по ssh — только UTF-8
        except (AttributeError, ValueError):
            pass
    ns = parser.parse_args(argv)
    try:
        _check_slot(ns.slot)
    except LiveClientError as e:
        print(e.message, file=sys.stderr)
        return 2
    if ns.cmd == "run":
        result = run_scenario(ns.slot, ns.dir, ns.scenario, ns.timeout)
        print(json.dumps({"ok": result.get("ok"), "error": result.get("error")}, ensure_ascii=False))
        return 0 if result.get("ok") else 1
    if ns.cmd == "wait-ready":
        return 0 if wait_ready(ns.slot, ns.dir, ns.timeout) else 1
    if ns.cmd == "check-log":
        return check_log(ns.slot, ns.dir)
    return 0 if send_quit(ns.slot, ns.dir) else 1


if __name__ == "__main__":
    sys.exit(main())
