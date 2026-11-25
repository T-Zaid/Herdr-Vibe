#!/usr/bin/env python3
"""Report Vibe CLI lifecycle state to Herdr (self-reporting protocol).

Invoked by Vibe's hook system (see hooks.toml); the hook event is passed as
the only argument and Vibe's JSON hook payload arrives on stdin. Uses only
the Python standard library, so any Python 3.8+ works.

Usage: herdr.py <start|working|notify|end>

Event -> Herdr state mapping:

  start   (session_start)              -> idle, plus resume info
                                          (vibe --resume <session_id>) so the
                                          pane can be restored after a Herdr
                                          restart
  working (pre_agent, post_tool)       -> working
  notify  (notification)               -> blocked on approval_requested /
                                          question_asked (with the prompt
                                          message), idle on turn_completed /
                                          turn_failed
  end     (session_end, reason=exit)   -> releases the pane back to Herdr;
                                          clear/other reasons are ignored
                                          (session_start of the replacement
                                          session reports next)

Requires the Herdr-injected environment: HERDR_ENV=1, HERDR_PANE_ID and
HERDR_BIN_PATH (falls back to a `herdr` on PATH). Silently does nothing when
run outside Herdr or on any error, so a broken hook never blocks a turn.

Deliberately NOT mapped: post_agent. Vibe fires post_agent after every
subagent turn too, which would flicker the pane to idle while the main turn
is still working; notification turn_completed covers main-agent turn ends.
"""

import json
import os
import shutil
import subprocess
import sys
import tempfile
import time

SOURCE = "vibe-hooks"
AGENT_LABEL = "vibe"
PROGRAM_TIMEOUT = 2  # seconds; must stay well under the hook timeout in hooks.toml


def herdr_binary():
    """Resolve the herdr CLI: HERDR_BIN_PATH first, then PATH."""
    candidate = os.environ.get("HERDR_BIN_PATH")
    if candidate and os.path.exists(candidate):
        return candidate
    found = shutil.which("herdr") or shutil.which("herdr.exe")
    if found:
        return found
    # Last resort: let the OS resolve `herdr` via PATH (works on Git Bash).
    return "herdr"


def state_file(pane):
    """Path of the small dedup-state file for this pane."""
    safe = pane.replace(":", "_").replace(os.sep, "_")
    return os.path.join(tempfile.gettempdir(), "herdr-vibe-state-%s.json" % safe)


def last_reported(pane):
    try:
        with open(state_file(pane), "r", encoding="utf-8") as fh:
            return json.load(fh)
    except Exception:
        return None


def save_reported(pane, key, session_id):
    try:
        with open(state_file(pane), "w", encoding="utf-8") as fh:
            json.dump({"key": key, "session_id": session_id}, fh)
    except Exception:
        pass


def run(pane, args):
    cmd = [herdr_binary(), "pane", args[0], pane] + args[1:]
    subprocess.run(
        cmd,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        timeout=PROGRAM_TIMEOUT,
    )


def report(pane, state, message=None, session_id=None, transcript_path=None):
    args = [
        "report-agent",
        "--source", SOURCE,
        "--agent", AGENT_LABEL,
        "--state", state,
        "--seq", str(time.time_ns()),
    ]
    if message:
        args += ["--message", message]
    if session_id:
        args += ["--agent-session-id", session_id]
    if transcript_path and os.path.exists(transcript_path):
        args += ["--agent-session-path", transcript_path]
    if session_id:
        args += ["--", "vibe", "--resume", session_id]
    run(pane, args)


def release(pane):
    run(pane, [
        "release-agent",
        "--source", SOURCE,
        "--agent", AGENT_LABEL,
        "--seq", str(time.time_ns()),
    ])


def handle(event, payload):
    pane = os.environ.get("HERDR_PANE_ID")
    session_id = payload.get("session_id")

    if event == "start":
        # Always report on session start: it also heals a stale `working`
        # left behind by an interrupted turn of a previous session.
        report(pane, "idle", session_id=session_id,
               transcript_path=payload.get("transcript_path"))
        save_reported(pane, "idle", session_id)
        return

    if event == "end":
        # Only a real exit releases the pane. `clear`/`other` mean the session
        # was replaced while Vibe keeps running; the new session's
        # session_start hook reports the fresh state.
        if payload.get("reason") == "exit":
            release(pane)
            save_reported(pane, "released", session_id)
        return

    if event == "working":
        key = "working"
    elif event == "notify":
        notification = payload.get("notification_type")
        if notification in ("approval_requested", "question_asked"):
            key = "blocked|%s" % (payload.get("message") or notification)
            report(pane, "blocked", message=payload.get("message"))
            save_reported(pane, key, session_id)
            return
        if notification in ("turn_completed", "turn_failed"):
            key = "idle"
            report(pane, "idle")
            save_reported(pane, key, session_id)
            return
        return
    else:
        return

    # Dedup consecutive identical reports: Vibe fires pre_agent and post_tool
    # many times per turn; only state *changes* need to reach Herdr.
    previous = last_reported(pane)
    if previous and previous.get("key") == key:
        return
    report(pane, "working")
    save_reported(pane, key, session_id)


def main():
    if os.environ.get("HERDR_ENV") != "1":
        return
    if not os.environ.get("HERDR_PANE_ID"):
        return
    if len(sys.argv) != 2 or sys.argv[1] not in ("start", "working", "notify", "end"):
        return
    try:
        payload = json.loads(sys.stdin.read() or "{}")
    except Exception:
        payload = {}
    handle(sys.argv[1], payload if isinstance(payload, dict) else {})


if __name__ == "__main__":
    # A hook must never take Vibe down with it.
    try:
        main()
    except Exception:
        pass
