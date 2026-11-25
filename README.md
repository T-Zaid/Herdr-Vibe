# Herdr-Vibe

Custom integration that makes the [Mistral Vibe CLI](https://github.com/mistralai/mistral-vibe)
a first-class agent in [Herdr](https://herdr.dev): lifecycle state reporting
(`idle` / `working` / `blocked`), notifications, and session restore after a
Herdr restart.

Built for [herdrdev/herdr#883](https://github.com/herdrdev/herdr/discussions/883)
("Add the integration with Mistral Vibe cli") using the **self-reporting
protocol** — no changes to Herdr itself, works on any Herdr release that ships
`herdr pane report-agent` / `release-agent` (tested on 0.9.5) and any Vibe
release with the hook system (hooks landed in Vibe 3.1.1; tested against 3.1.4+).

## How it works

```
Vibe hook event          Vibe hook type      ->  herdr.py  ->  Herdr state
------------------------ -------------------     -----------   ----------------------
session starts           session_start       ->  start      ->  idle (+ resume args)
turn begins / tool runs  pre_agent, post_tool ->  working   ->  working
tool needs approval      notification         ->  notify     ->  blocked (+ message)
turn completed/failed    notification         ->  notify     ->  idle
user answers question    question_asked       ->  notify     ->  blocked (+ message)
Vibe exits               session_end(exit)    ->  end        ->  pane released
```

The hook script (`hooks/herdr.py`, stdlib-only Python) receives Vibe's JSON
hook payload on stdin and calls:

```bash
herdr pane report-agent <pane> --source vibe-hooks --agent vibe \
    --state <state> --seq <ns> --agent-session-id <id> \
    --agent-session-path <transcript> -- vibe --resume <id>

herdr pane release-agent <pane> --source vibe-hooks --agent vibe --seq <ns>
```

Because reports are self-serialized (`--seq`) and namespaced `--source
vibe-hooks`, they compose safely with Herdr's own detection and with other
reporters.

### Session restore

Every state report carries `--agent-session-id` and the resume command
(`vibe --resume <session-id>`), so if Herdr restarts, the pane comes back into
the same Vibe conversation — the same behavior native integrations get.

## Install

From a Herdr pane, in this repo:

```bash
./install.sh
```

The installer:

1. detects a Python 3.8+ interpreter (`python3` / `python` / `py`);
2. copies `hooks/herdr.py` to `~/.vibe/hooks/herdr.py`;
3. appends a marked `# >>> herdr-vibe >>> ... <<<` hook block to
   `~/.vibe/hooks.toml`, leaving any existing hooks untouched
   (re-running it upgrades the block in place).

Then start (or restart) Vibe in a Herdr pane. That's it — the next session
reports its lifecycle.

## Uninstall

```bash
./uninstall.sh
```

Removes the marked block from `~/.vibe/hooks.toml`, deletes
`~/.vibe/hooks/herdr.py`, and releases the current pane's `vibe` registration.

## Self-test

From a Herdr pane:

```bash
./test.sh
```

Drives a fake session through `idle -> working -> blocked -> idle -> release`
against the live Herdr server and prints `herdr agent get` after each step.

## State reference

| Herdr state | When |
|---|---|
| `idle` | Vibe session started; turn completed; turn failed |
| `working` | Turn in progress (`pre_agent`), between/inside tools (`post_tool`) |
| `blocked` | `approval_requested` or `question_asked` (message shown by Herdr) |
| released | Vibe exited cleanly |

## Known gaps (and why)

- **Interrupting a turn (Esc / Ctrl+C) fires no Vibe hook**, so the pane can
  stay `working` until the next turn ends or a new session starts. Tracked on
  the Vibe side ([mistralai/mistral-vibe#1424](https://github.com/mistralai/mistral-vibe/issues/1424));
  Mistral is looking at reporting to Herdr natively. Mitigation: the next
  session's `session_start` report heals the state; or press Enter/queue
  anything to move the state forward.
- **Crash / SIGKILL of Vibe** fires no `session_end`, same effect as above.
- **Subagent turns** are deliberately *not* reported: Vibe's `post_agent` hook
  also fires after every subagent turn, which would flicker the main pane to
  `idle` mid-turn. `notification: turn_completed` covers main-agent turns only.
- **`herdr agent start --kind vibe`** requires Herdr to ship a `vibe` kind —
  that's an upstream change (see the discussion). Companion apps that only
  offer `--kind`-listed agents can still target a Vibe pane once Herdr adds
  the kind; state reporting from this integration already works regardless.

## Requirements

- Herdr >= release with `pane report-agent` / `pane release-agent` (0.9.5 tested)
- Vibe >= 3.1.1 (hook system)
- Python 3.8+ on PATH (Windows: Git Bash resolves `python3`/`python`/`py`)
- Running inside a Herdr pane: the reporter is a no-op when `HERDR_ENV != 1`

## Files

```
Herdr-Vibe/
├── hooks/herdr.py    # the reporter (installed to ~/.vibe/hooks/herdr.py)
├── hooks.toml        # canonical hook definitions (installed into ~/.vibe/hooks.toml)
├── install.sh        # idempotent installer (Git Bash / macOS / Linux)
├── uninstall.sh      # clean removal
└── test.sh           # live end-to-end state test
```

## Troubleshooting

- **Pane shows nothing**: check `herdr agent get <pane-id>`; the hook only
  reports when `HERDR_ENV=1` and `HERDR_PANE_ID` are set, i.e. Vibe was
  started from a Herdr pane *after* the integration was installed.
- **Hook errors in Vibe**: `~/.vibe/hooks/herdr.py` never raises — if Vibe
  shows hook warnings, check that the `command` in `~/.vibe/hooks.toml` names
  an existing Python interpreter (re-run `./install.sh` to fix).
- **Stuck `working` after an interrupt**: expected (see Known gaps); start a
  new session or finish the next turn to heal it.
