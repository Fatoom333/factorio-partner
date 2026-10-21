# factorio-partner

**English** | [Русский](README.ru.md)

An AI agent plays a second character in your Factorio 2.0 (Space Age) save: it walks, mines, crafts and builds
by the same rules as a player. You give it orders such as "set up mining on this ore patch" and it works in
real time while you play. It is an ordinary MCP server, so any MCP-capable agent can drive it; the repository
also ships richer role files for Claude Code.

> Detailed docs (`docs/`) are in Russian. This README is the English entry point.

## Contents
- [Install with an agent (one prompt)](#install-with-an-agent-one-prompt)
- [How it works](#how-it-works)
  - [Honesty rules](#honesty-rules)
- [Features](#features)
- [Requirements](#requirements)
- [Quick start (by hand)](#quick-start-by-hand)
  - [1. Install the mod](#1-install-the-mod)
  - [2. Enable RCON](#2-enable-rcon)
  - [3. Install the server](#3-install-the-server)
  - [4. Connect an MCP client (any agent)](#4-connect-an-mcp-client-any-agent)
  - [5. Claude Code add-on (roles, workflows)](#5-claude-code-add-on-roles-workflows)
  - [6. Roles in other agents](#6-roles-in-other-agents-codex-cli-gemini-cli-opencode-cursor)
- [Mod settings](#mod-settings)
  - [Owner words in chat](#owner-words-in-chat)
  - [Owner panel](#owner-panel)
- [Project layout](#project-layout)
- [Testing](#testing)
- [Documentation (Russian)](#documentation-russian)
- [License and credits](#license-and-credits)

## Install with an agent (one prompt)
Open your coding agent (Claude Code, Codex CLI, Gemini CLI, OpenCode, Cursor…) in an empty folder and paste
the prompt below. The agent downloads everything and sets it up; it asks you before touching the game's
`config.ini` and never needs the game to be running until the last step.

```text
Set up factorio-partner (https://github.com/Fatoom333/factorio-partner) on this computer for me.
Follow its README, section "Quick start (by hand)". Steps:
1. Clone the repository into the current folder and check out the latest release tag
   (https://github.com/Fatoom333/factorio-partner/releases/latest).
2. Find the Factorio user data folder (Windows: %APPDATA%\Factorio, Linux: ~/.factorio,
   macOS: ~/Library/Application Support/factorio; if it is elsewhere, ask me).
   Download factorio-partner_<version>.zip from that release into its mods folder (do not unpack it).
   If mods/mod-list.json exists, make sure factorio-partner is listed with "enabled": true.
3. Create a Python 3.11+ virtual environment outside the repository folder and install the server into it:
   <venv python> -m pip install -e "<repo>/server". Use only that venv; install nothing system-wide.
4. RCON: generate a random password, save it alone in a one-line file outside the repository
   (for example next to the venv), and never print it in the chat. Then ask me before editing the game's
   config/config.ini: the game must be closed; back the file up first; set
   local-rcon-socket=127.0.0.1:27015 and local-rcon-password=<that password> in the [other] section.
5. Create the MCP server entry named "partner" for THIS client in its own config format, with
   command = <venv python>, args = ["-m", "factorio_partner.server"] (never --admin) and env FP_HOME
   (a data folder outside the repository), FP_RCON_HOST=127.0.0.1, FP_RCON_PORT=27015,
   FP_RCON_PASSWORD_FILE=<the password file>.
6. Tell me to start Factorio, load my save via "Multiplayer -> Host saved game" and say "ready".
   Then run <venv python> <repo>/agents/launch.py --helpers 1 --body character --client <this client>
   (claude, codex, gemini, opencode or cursor) and follow what it prints; for one agent without roles use
   the rules from .claude/agents/partner.md and the prompt from FP_HOME/launch/session.json.
Do not run Factorio console commands, do not put the password or helper keys into the repository or the chat.
At the end, tell me in short what you did and where each file is.
```

After it finishes you only give orders in the game chat ("come here", "set up mining on this ore patch").
If something fails, the manual steps below are the reference.

## How it works

```
agent (any LLM) ── MCP (stdio) ──> server (Python) ── RCON ──> Factorio + mod
```

- `mod/factorio-partner/` — the mod (Lua): the helper's body, task queue, events, reflexes.
- `server/` — the MCP server (Python): the bridge between the agent and the mod over RCON.
- `agents/` — launcher, chat style, example orders; agent rules live in `.claude/agents/partner.md`.
- `tools/pc/` — test rig: a headless Factorio server on a copy of a save, plus live scenarios.
- `docs/` — protocol, actions, events and state reference (Russian).

The helper is a separate `character` entity with no player behind it, in the owner's force (the owner is
whoever owns the save). The agent writes no game code: it calls ready-made MCP tools, the server validates the
arguments and sends them to the mod, the mod performs the action and reports events. Reflexes (retreat from an
enemy, respawn) run inside the mod, so the agent can "sleep" between events.

### Honesty rules
- The only way into the game is the mod command `/partner <JSON>` over RCON. The console commands `/c` and
  `/sc` are never used, so **achievements stay enabled**.
- No teleporting and no items from thin air: materials come from the helper's inventory, chests and the
  ground, paths are walked on foot, buildings are placed within reach.
- Only the owner gives the helper orders; any other chat message is treated by the agent as data, not as a command.

## Features
- **Perception:** map around the helper, ore, storage, ghosts, production and its rates, recipes, item search
  across the whole base, landmass shape and exits from the area, an encyclopedia-style lookup, "what is made
  of what and where to get it".
- **Movement:** pathfinding walk, approach, following the owner, getting unstuck.
- **Hands:** mining (including collecting an item from rocks in a row), background crafting, moving items,
  picking up from the ground, changing the recipe of an idle machine.
- **Building:** placing buildings, blueprints with Shift-style placement modes, landfill and foundation by tile
  properties from the game, building by hand or with personal robots, deconstruction.
- **Planning:** mining layouts from Mining Patch Planner patterns, a belt from the mine to the base routed
  around liquid and buildings; blueprint design through factorio-forge (`partner_plan`) if installed.
- **Combat and reflexes:** retreat and return to the task, turret refuelling and shooting (only on the
  owner's word), respawn after 10 seconds; evacuation of buildings from any enemies (dismantle on threat,
  rebuild when it is quiet).
- **Strategist tasks for the pilot:** the strategist gives the body any honest job (watch duty, armor, guard,
  fetch) through `partner_task`; whatever the body cannot do, the pilot reports plainly (`no_tool`).
- **Chat:** the helper answers in the game chat under its own name (setting `partner-helper-name`), `[gps]`
  tags in chat are clickable; the owner's rules are remembered after confirmation in game. The strategist and
  pilot ask the owner questions right in the game chat and take the answer themselves; "forget" / "cancel"
  drops a package, task or question at once.
- **Several helpers** — set the number at launch, or later by words in game ("start / add / remove N helpers")
  or with a button in the panel window.
- **Settings and panel** — what the helper may do, what it must ask about and what is forbidden; an owner
  window with buttons.

## Requirements
- Factorio 2.0.x (verified on 2.0.77 with Space Age; the mod itself depends only on `base >= 2.0.0`).
- Python 3.11 or newer.
- An MCP-capable agent (any client that can launch a stdio MCP server). Claude Code gets a richer setup (below).
- A way to turn on RCON: hosting the save from the main menu (multiplayer host) or a dedicated server.

## Quick start (by hand)

### 1. Install the mod
Download `factorio-partner_<version>.zip` from the latest
[release](https://github.com/Fatoom333/factorio-partner/releases/latest), put it into the game's `mods`
directory as is (do not unpack) and enable the mod in the game's mod list. Use the server and agent files from
the same release tag.

To build it from the source instead, put the folder `mod/factorio-partner/` into the game's `mods` directory as `factorio-partner_<version>`
(`<version>` is from `info.json`), either as a folder or as a zip with a single top-level folder of the same
name. The repository can build the zip for you:

```
python tools/pc/pack.py mod --src mod/factorio-partner --out <output folder>
```

It prints the path to the zip. Enable the mod in the game's mod list.

### 2. Enable RCON
RCON must listen on `127.0.0.1`. For a save you host from the menu ("Multiplayer → Host saved game"), set in
`config.ini` (or in the hidden settings: Ctrl+Alt in the main menu, then "Settings", section "The rest"):

```
local-rcon-socket=127.0.0.1:27015
local-rcon-password=<password>
```

A dedicated server uses `--rcon-port`, `--rcon-bind` and `--rcon-password` instead. Single-player games get
no RCON. Keep the password in a one-line file outside the repository; the server only ever reads the path.

### 3. Install the server
```
python -m venv <venv folder>
<venv>/bin/python -m pip install -e "server[dev]"        # Windows: <venv>\Scripts\python
```
Dependencies (from `server/pyproject.toml`): `mcp>=1.12,<2` and `factorio-rcon-py[async]>=2.1,<3`. The package
also installs two commands, `factorio-partner-mcp` (the MCP server) and `factorio-partner-cli` (JSON in/out for
debugging). Run it by hand with `python -m factorio_partner.server` (speaks MCP over stdio).

Server configuration is by environment variables:

| variable | meaning |
|---|---|
| `FP_RCON_HOST` | `127.0.0.1` (default) or `localhost`; anything else is refused |
| `FP_RCON_PORT` | RCON port, default `27015` |
| `FP_RCON_PASSWORD_FILE` | path to the one-line password file (required) |
| `FP_HOME` | data folder (helper keys `helpers.json`, `style.md`, logs, launch files); default `%LOCALAPPDATA%\factorio-partner`, otherwise `~/.local/share/factorio-partner` |
| `FP_FORGE`, `FP_FORGE_PROFILE` | optional: factorio-forge checkout and save profile for `partner_plan` |

The full list is in [docs/MCP.md](docs/MCP.md) and [server/README.md](server/README.md).

### 4. Connect an MCP client (any agent)
The owner must be in the game (the helper appears next to them). Prepare helpers with the launcher, using the
venv's Python so it can import the server package:

```
<venv python> agents/launch.py --helpers 1 --body character
```

The launcher asks how many helpers and which kind of body if you do not pass flags, issues per-helper keys
into `FP_HOME/helpers.json`, creates the bodies in the game (only `/partner <JSON>` goes to the game), and
writes two files under `FP_HOME/launch/`:

- `mcp.json` — the MCP server config;
- `session.json` — the first message for each agent (`helpers[].prompt`; it contains the helper id and key).

Every tool takes `helper` and `key` arguments; the key is how the server tells helpers (and roles) apart. Keys
live only under `FP_HOME`: do not copy them into the repository or into shared chats.

**The MCP server entry** (this is what `launch.py` writes; see `agents/mcp.example.json`). The server name must
be `partner`, because the rules refer to tools as `partner_*`:

```json
{
  "mcpServers": {
    "partner": {
      "command": "<python from the venv where the server package is installed>",
      "args": ["-m", "factorio_partner.server"],
      "env": {
        "FP_HOME": "<data folder, outside the repository>",
        "FP_RCON_HOST": "127.0.0.1",
        "FP_RCON_PORT": "27015",
        "FP_RCON_PASSWORD_FILE": "<path to the RCON password file, outside the repository>"
      }
    }
  }
}
```

Paste that entry into your client's MCP configuration (the same `mcpServers` shape most clients use). Do not
start the server with `--admin` for agents: that flag exposes launcher-only `admin_*` tools.

**Single-agent mode.** Use the body of [`.claude/agents/partner.md`](.claude/agents/partner.md) (everything
after the front-matter block) as the agent's system prompt: it holds the honesty rules, the order cycle, how to
wait, how to read refusals and the reflexes. Use `helpers[0].prompt` from `FP_HOME/launch/session.json` as the
first user message. The agent then works through the 21 `partner_*` tools it is allowed (state, map, resources,
stock, find, access, status, ghosts, rates, recipes, supply, lookup, notes, act, cancel, hold, wait, reflex,
say, plan, brief); the tool table is in [docs/MCP.md](docs/MCP.md). The owner gives orders in the game chat; the
agent hears them through `partner_wait`. If the agent finishes a shift, restart it with a short summary and the
same key.

### 5. Claude Code add-on (roles, workflows)
For Claude Code the repository ships more:

- **Agent types** in `.claude/agents/` (Claude Code reads them when launched from the repository root):
  `partner` (one agent per helper, no roles) and three role agents — `partner-voice` (talks to the owner and
  passes orders on), `partner-pilot` (drives one body) and `partner-strategist` (designs what to build). One
  voice and one strategist serve all helpers; there is one pilot per body. Each role has its own tool
  allowlist and its own key (roles are described in [docs/MCP.md](docs/MCP.md)).
- **Launcher modes:** `agents/launch.py --roles` prepares role keys and one MCP config per role
  (`mcp-voice.json`, `mcp-pilot.json`, `mcp-strategist.json`). `--pilot-model sonnet|haiku` and
  `--strategist-model sonnet|opus` pick models; values not passed on the command line come from the mod
  settings.
- **Workflows** in `agents/workflows/`: `partner-play.js` (one `partner` agent per helper, shifts until the
  owner tells it to stand down ("отбой" in the chat) and `partner-roles.js` (role loops: voice, strategist and a pilot per
  body, so N helpers means N+2 loops).

Typical run:

```
<venv python> agents/launch.py --helpers 2 --body character --roles
claude --mcp-config "<FP_HOME>/launch/mcp.json"
# then run the workflow agents/workflows/partner-roles.js with the contents of <FP_HOME>/launch/session.json
```

For one helper without roles: `claude --agent partner --mcp-config "<FP_HOME>/launch/mcp.json"` and paste the
helper's `prompt` from `session.json` as the first message. Details, `session.json` layout, restarting for a
different number of helpers and relaying owner words from the main chat: [agents/README.md](agents/README.md).

### 6. Roles in other agents (Codex CLI, Gemini CLI, OpenCode, Cursor)
The three roles (voice, pilot, strategist) and the single `partner` agent are also shipped for other clients.
They are generated from the Claude Code files in `.claude/agents/` by `python agents/roles_export.py` (the body
with the rules is identical; only the frontmatter is translated). `python agents/roles_export.py --check` fails
if the copies are stale; `agents/lint.py` runs it. Models are inherited from the main session, and no tool list
is written: the server decides what each role may call by the key in its first message.

Common steps: run `agents/launch.py --client <codex|gemini|opencode|cursor> --helpers N --body character`
(roles mode is implied). Besides the shared `mcp.json` it writes, under `<FP_HOME>/launch/`, the MCP entry in the
client's own format and `first-message.md`: a ready message for the main agent that asks it to start the roles
as subagents and gives each role its own first message (with its key). Put the MCP entry into the client's
config, open the client in the repository root, paste `first-message.md`. The launcher never starts the server
with `--admin` and never writes the RCON password, only the path of its file.

| Client | Agent files | MCP entry from `launch/` goes to | Start |
|---|---|---|---|
| Codex CLI | `.codex/agents/*.toml` | `.codex/config.toml` or `~/.codex/config.toml` (`mcp-codex.toml`, table `[mcp_servers.partner]`) | ask the main agent to spawn the voice, pilot and strategist agents |
| Gemini CLI | `.gemini/agents/*.md` | `.gemini/settings.json` (`mcp-gemini.json`, also sets `experimental.enableAgents`) | the main agent calls `@partner-voice` etc. |
| OpenCode | `.opencode/agents/*.md` | `opencode.json` (`mcp-opencode.json`, section `mcp`) | `@partner-voice` or the primary agent's Task tool |
| Cursor | `.cursor/agents/*.md` | `.cursor/mcp.json` (`mcp-cursor.json`) | ask the main agent to run the subagents; they run in the background |

Caveats:
- Only Claude Code has been tested live. The other formats are generated to their documented formats and
  checked by tests (valid TOML / frontmatter, same body), not played with.
- Codex and Cursor subagents inherit the parent's MCP servers, so every role sees all `partner_*` tools. This is
  safe: the server refuses calls outside the role of the key (`access denied`). Codex agents cannot declare their
  own MCP servers, so the entry must be in the config of the session that spawns them.
- Gemini CLI limits steps and time per agent; the generated files set `max_turns: 500` and `timeout_mins: 720`.
  Subagents may need `"experimental": {"enableAgents": true}` in `settings.json` (included in `mcp-gemini.json`).
  The `tools` list is left out because the MCP tool naming differs between clients.
- Cursor also reads `.claude/agents/` and `.codex/agents/`; the generated `.cursor/agents/` takes precedence.
- The roles are long loops (wait for an event, answer, repeat). If a client ends a subagent, start it again with
  the same first message. Details: [agents/README.md](agents/README.md).

## Mod settings
All mod settings are under "Settings → Mod settings → Map", prefix `partner-`. Only the owner changes them and
they apply immediately. Every permission has three values: **auto** (`auto`: the helper just does it), **ask**
(the helper asks in chat first and acts only after an explicit "yes") and **deny** (`deny`: the mod refuses
even if the owner said "yes").

| setting | default | allows |
|---|---|---|
| `perm-take-chests` | auto | take from the owner's free chests |
| `perm-take-lines` | ask | take from line outputs and machines (`from_lines`) |
| `perm-take-inputs` | deny | take from machine inputs and fuel |
| `perm-build` | auto | build: placement, blueprints, blocks, belts, mining |
| `perm-superforced` | ask | a blueprint that demolishes obstacles (`force:"superforced"`) |
| `perm-deconstruct-own` | auto | dismantle the helpers' buildings, change recipes in their machines |
| `perm-deconstruct-owner` | ask | dismantle the owner's buildings |
| `perm-set-recipe` | ask | change the recipe in an owner's machine |
| `perm-chop` | auto | chop trees, mine rocks (ore is always allowed) |
| `perm-smelt` | auto | smelt in the owner's free furnaces |
| `perm-spend` | ask | one build spends more than `spend-limit` items (200) |
| `perm-shoot` | ask | enable the shooting reflex |
| `perm-turrets` | auto | enable turret refuelling |
| `perm-upkeep` | ask | enable building upkeep |
| `perm-attack-nests` | deny | shoot nests and worms |
| `perm-walk-far` | auto | go farther than `far-distance` tiles from the owner (300) |
| `perm-leave-planet` | deny | act on another surface |
| `perm-auto` | ask | autonomous AUTO mode: "auto" — without a "yes", "deny" — never enable |

| setting | default | what it does |
|---|---|---|
| `helpers` | 1 (1..5) | how many helpers to start |
| `pilot-model`, `strategist-model` | sonnet | pilot model (sonnet, haiku) and strategist model (sonnet, opus) |
| `thoughts` | off | show the strategist's thoughts in chat by default |
| `voice-pause` | 2.5 s (0..6) | voice pause: wait until the owner finishes typing |
| `budget-strategist`, `budget-voice-only`, `budget-weekly` | 70, 85, 90 % | thresholds of the usage-limit guard |
| `flee-health` | 40 % (5..95) | retreat below this health |
| `auto-armor` | on | put armor on after respawn and after picking up the corpse |
| `turret-standoff`, `turret-gap` | on, 3 (1..10) | the refueller stands behind the turret line, no closer than the gap |
| `answer-every` | on | the voice answers every owner message |
| `reply-lines` | 2 (1..6) | the voice answers in at most this many lines |

Contracts: [PROTOCOL](docs/PROTOCOL.md) (the `settings` operation, the `owner_ok` field, the `owner_forbids`
and `needs_owner_ok` codes), [ACTIONS](docs/ACTIONS.md) ("Разрешения хозяина"), [MCP](docs/MCP.md).

### Owner words in chat
The mod itself parses the owner's chat messages (nobody else's), in the same tick and without a model; the
word lists have Russian and English defaults and the stop words are a mod setting (`partner-stop-words`).
Address one helper by name ("Claude2, stop") or all of them by not naming anyone. "Forget" is the exception:
it is understood by the voice agent, not parsed by the mod.

| you say | what happens |
|---|---|
| stop (`стоп`, `stop`) | cancels all tasks and manual crafting and puts the body on hold |
| come here (`иди сюда`, `come`, `come here`) | stops, then follows you |
| what are you doing (`что делаешь`, `status`) | answers with the current action |
| continue (`продолжай`, `continue`) | releases the hold |
| forget / cancel (`забудь`, `отмени`, "forget it") | the voice agent drops the named package, task or question at once |
| don't guard (`не охраняй`, `stop guarding`, `unguard`) | removes the guard you set with the button |

Exact rules and edge cases: [docs/EVENTS.md](docs/EVENTS.md) ("Слово хозяина").

### Owner panel
A robot icon in the shortcut bar (right-click the bar to hide it) opens a window; the hotkey
`partner-toggle-panel` is unbound by default. In the window: a row per body and what it is doing; the number
of helpers with an "Apply" button; "Stop all" and "Continue"; checkboxes "Strategist thoughts" and "AUTO"
(with a goal field); a "Combat mode" switch (shooting and turret refuelling for all bodies, unless forbidden
in settings); "Guard here" and "Remove guard" buttons (the guard evacuates buildings around your position when
enemies approach, and only you can remove a guard you set). Details: [docs/EVENTS.md](docs/EVENTS.md)
("Панель хозяина").

## Project layout
```
mod/factorio-partner/   the mod (control.lua, scripts/, settings.lua, locale/)
server/                 MCP server (factorio_partner/), its tests
agents/                 launch.py, lint.py, workflows/, examples/, style.md, tests/
.claude/agents/         agent rules: partner, partner-voice, partner-pilot, partner-strategist
tools/pc/               live test rig (headless server, scenarios)
docs/                   reference documentation (Russian)
CHANGELOG.md            mod version history
```

## Testing
```
python tools/run_lua_tests.py        # mod unit tests (needs lupa: tools/requirements-dev.txt, in a venv)
cd server && python -m pytest -q     # server tests with a fake RCON server
python agents/lint.py                # agent rules check, no game needed
python -m pytest -q agents/tests     # same plus launcher tests (needs the venv with server[dev])
```
Live tests on a headless Factorio server and end-to-end scenarios: [docs/TESTING.md](docs/TESTING.md),
[docs/E2E.md](docs/E2E.md), [tools/pc/README.md](tools/pc/README.md).

## Documentation (Russian)
- [ARCHITECTURE](docs/ARCHITECTURE.md) — how the project is built.
- [PROTOCOL](docs/PROTOCOL.md) — mod ↔ server protocol, honesty.
- [ACTIONS](docs/ACTIONS.md) — helper actions.
- [EVENTS](docs/EVENTS.md) — events and reflexes.
- [STATE](docs/STATE.md) — reading world state.
- [MCP](docs/MCP.md) — MCP server tools.
- [TESTING](docs/TESTING.md) — tests and the rig.
- [ENGINE-NOTES](docs/ENGINE-NOTES.md) — what to know about the Factorio engine.
- [DECISIONS](docs/DECISIONS.md) — decisions and status.
- [CHANGELOG](CHANGELOG.md) — mod version history.

## License and credits
[MIT](LICENSE). Ideas taken, code written from scratch:
- [Rate Calculator](https://github.com/raiguard/RateCalculator) (MIT) — machine rate calculation in `rates`;
- [Mining Patch Planner](https://mods.factorio.com/mod/mining-patch-planner) (MIT) — drill layouts;
- [Wuastbude Belt & Pipe Router](https://mods.factorio.com/mod/wuastbude-router) (MIT) — belt routing in `plan_belt`;
- [Factory Search](https://github.com/tburrows13/FactorySearch) (MIT) — base search in `find`;
- [linsyking/factorio-mcp](https://github.com/linsyking/factorio-mcp) and
  [Factorio Learning Environment](https://github.com/JackHopkins/factorio-learning-environment) — examples of
  connecting an agent to the game.
