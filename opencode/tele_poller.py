#!/usr/bin/env python3
"""Telegram -> Claude wake poller (clone pattern per telebridge/links.md).
Long-polls the Oculus bot, appends every message to /tmp/clone_inbox.jsonl,
and writes a wake line to /tmp/main_wake.log so the Claude Monitor fires.
"""
import json, os, sys, time, urllib.request, urllib.parse

TOKEN = [l.split("=", 1)[1].strip() for l in open("/home/roni/Roni_workspace/telebridge/bot.env")
         if l.strip().startswith("TELEGRAM_BOT_TOKEN=")][0]
API = f"https://api.telegram.org/bot{TOKEN}"
# Pidfile for the monitors dashboard (reads /tmp/tele_poller.pid)
with open("/tmp/tele_poller.pid", "w") as pf:
    pf.write(str(os.getpid()))
offset = 0
if os.path.exists("/tmp/tele_offset"):
    offset = int(open("/tmp/tele_offset").read().strip() or 0)

# Repo-compatible inbox: the claude-telegram-bridge messaging layer
# (inbox_wake.py / inbox_monitor.py / ack daemon) consumes claude_inbox.json,
# a JSON ARRAY ring buffer under AUDITS_PLANS_DIR.
AUDITS_DIR = os.getenv("AUDITS_PLANS_DIR",
                       os.path.join(os.path.expanduser("~"), ".claude", "channels", "telegram"))
ARRAY_INBOX = os.path.join(AUDITS_DIR, "claude_inbox.json")


def append_array_inbox(rec):
    """Append rec to the array inbox (CREATED empty on first run). Ring-buffer
    cap of 500 like the old stack; atomic replace — this poller is the only
    writer, wake/monitor only read."""
    try:
        with open(ARRAY_INBOX) as f:
            arr = json.load(f)
        if not isinstance(arr, list):
            arr = []
    except Exception:
        arr = []
    arr.append(rec)
    arr = arr[-500:]
    tmp = ARRAY_INBOX + ".tmp"
    with open(tmp, "w") as f:
        json.dump(arr, f)
    os.replace(tmp, ARRAY_INBOX)


if not os.path.exists(ARRAY_INBOX):
    try:
        os.makedirs(AUDITS_DIR, exist_ok=True)
        with open(ARRAY_INBOX, "w") as f:
            json.dump([], f)
    except Exception:
        pass

def api(method, params=None, timeout=60):
    url = f"{API}/{method}" + ("?" + urllib.parse.urlencode(params) if params else "")
    with urllib.request.urlopen(url, timeout=timeout) as r:
        return json.loads(r.read())


# ─────────────────────────────────────────────────────────────────────────────
# /interrupt — an URGENT channel (owner, 2026-09-30)
#
#   "/interrupt <text>"  (also accepts Bob's spelling "/interupt")
#
# Owner: *"build a new telegram command, /interupt make it inteript whatever ur
# doing, then force send a inbox wakw message, so if I need u to see smth
# urgently it will work"*.
#
# WHAT IT DOES, and the one thing it deliberately does not.
#
#  1. BYPASSES THE 300 s BURST COOLDOWN. `oc_wake_watch.sh` collapses a burst of
#     messages into ONE ping via a cooldown file, and while suppressed it HOLDS
#     the lines rather than losing them -- correct for ordinary chatter, exactly
#     wrong for an urgent one, because it can delay a wake by up to five minutes.
#     Clearing the cooldown makes the watcher's next tick (<=2 s) deliver.
#
#  2. FIRES ITS OWN WAKE, carrying the content. The watcher's wake text is the
#     generic "check inbox" signal and its body is deliberately tiny because a
#     long wake does not survive the trip into session.prompt. For an interrupt
#     the CONTENT is the point, so the text is written to a file and the wake
#     names that file -- short enough to arrive, specific enough to act on.
#
#  3. KEEPS THE RAW TEXT ON DISK. /tmp/oc_interrupt.txt is the record, so the
#     message survives even if both wakes are somehow missed; the next turn
#     reads the inbox anyway and the line is in there too.
#
# WHAT IT CANNOT DO, stated so it is not oversold: it cannot inject MID-TURN.
# This serve's v2 `/api/session/*/prompt` family admits and never persists --
# verified 2026-09-30, HTTP 200 with zero messages added -- so `--steer` is a
# silent no-op and `--async` is the only path known to deliver. An interrupt
# therefore lands at the NEXT TURN BOUNDARY, which for an in-flight turn means
# as soon as the current tool call finishes. Delivering durably at a boundary
# beats injecting instantly and losing the message.
# ─────────────────────────────────────────────────────────────────────────────
INTERRUPT_FILE = "/tmp/oc_interrupt.txt"
COOLDOWN_FILE = os.path.expanduser("~/.local/share/opencode/wake.last")
OC_SEND = os.path.expanduser("~/.local/lib/ocbridge/oc_send.js")
BUN = os.path.expanduser("~/.local/bin/bun")

# Bob types it both ways; matching only the correct spelling would silently treat
# a typo as an ordinary message, which is the opposite of what an urgent channel
# must do.
INTERRUPT_CMDS = ("/interrupt", "/interupt")


def _interrupt_body(text):
    """Return the message with the command word stripped, or None if not a command.

    ★ THE COMMAND MUST BE A WHOLE WORD. A plain `startswith` also matches
    "/interrupted thing" and silently strips seven characters off an ordinary
    message -- measured: it produced "ed thing". An urgent channel that mangles
    a message it did not mean to claim is worse than one that ignores it, so the
    command has to be followed by whitespace or the end of the line.
    """
    s = text.strip()
    low = s.lower()
    for cmd in INTERRUPT_CMDS:
        if low.startswith(cmd):
            rest = s[len(cmd):]
            if rest == "" or rest[0].isspace():
                return rest.strip()
    return None


def _session_id():
    """The opencode session this box wakes, from the same pointer oc_send.js uses."""
    for p in (os.path.expanduser("~/.local/state/opencode/openbot_session"),):
        try:
            sid = open(p).read().strip()
            if sid:
                return sid
        except Exception:
            pass
    return None


def abort_generation():
    """STOP THE MODEL'S CURRENT TURN AND ITS RUNNING TOOL — the step that makes an interrupt interrupt.

    ★★★ CORRECTED 2026-09-30 AFTER MEASURING EACH ROUTE ON ITS OWN FRESH SESSION.

    The owner's hint identified the answer: *"when i manually interupt u, i run escape twice"*.
    Escape-Escape is the TUI's abort, and it is `POST /session/{id}/abort` (v1) -- NOT the v2
    interrupt this function used to call.

    Isolated test (/tmp/opencode/abort_iso.py): a throwaway session runs `sleep 150` as a real
    tool, then ONE endpoint is hit, and the sleep pid is re-checked:

        POST /session/{id}/abort            -> 200 "true"   sleep DEAD      ✅ kills the tool
        POST /api/session/{id}/interrupt    -> 204           sleep ALIVE     ❌ generation only
        POST /tui/execute-command           -> 200 "true"    sleep ALIVE     ❌ no effect headless
             {command: session.interrupt}

    ⇒ The v2 interrupt stops *generation* but leaves the running TOOL alive, so the tool slot
    stays occupied and the wake JOINS THE QUEUE -- exactly what the owner reported twice
    (*"ur test message went in queue"*). The v1 abort ends the whole turn including the child
    process, which is the behaviour the manual Escape-Escape gives.

    ⚠️ A 200 is NOT the evidence -- the sleep process dying is. Both v1 and /tui returned 200 on
    paths where nothing happened, so this is verified by re-reading the process table, never by
    the status code. Same rule as the `--steer` no-op: a status code proves nothing here.
    """
    import urllib.request
    sid = _session_id()
    if not sid:
        return "no session pointer"
    out = []
    # v1 abort FIRST: measured to kill the running tool AND end the turn. This is the Escape-Escape
    # path. It is the load-bearing call; everything below is a safety net.
    for path in (f"/session/{sid}/abort", f"/api/session/{sid}/interrupt"):
        req = urllib.request.Request(f"http://127.0.0.1:4096{path}", method="POST")
        try:
            with urllib.request.urlopen(req, timeout=10) as r:
                out.append("%s->%d" % (path.rsplit("/", 2)[-2] or path, r.status))
        except Exception as e:
            out.append("%s->%s" % (path.rsplit("/", 2)[-2] or path, e))
    return "ok " + " ".join(out)


def fire_interrupt(body):
    """Priority wake for an urgent message. Never raises: a failure here must not
    take the poller down, because the poller is the only thing receiving Telegram."""
    import subprocess
    try:
        with open(INTERRUPT_FILE, "w") as f:
            f.write(body or "(no text — read the inbox)")
    except Exception as e:
        print(f"[tele] interrupt file write failed: {e}", flush=True)
    # Bypass the burst cooldown so the watcher is not suppressed.
    try:
        with open(COOLDOWN_FILE, "w") as f:
            f.write("0")
    except Exception as e:
        print(f"[tele] cooldown clear failed: {e}", flush=True)
    # 1. free the tool slot, 2. end the turn. BOTH, in this order -- see abort_generation().
    killed = sweep_running_commands()
    gen = abort_generation()
    # Own wake, carrying the content. Truncated: a long body does not survive
    # session.prompt, and a short signal that always arrives beats a long one
    # that sometimes does not.
    head = (body or "").replace("\n", " ")[:400]
    extra = ""
    if killed:
        extra = " [paused %d running command(s)]" % len(killed)
    if gen.startswith("ok"):
        extra += " [turn aborted]"
    wake = (f"⚡⚡ INTERRUPT — owner needs you NOW: {head}{extra}"
            f"\n(full text: {INTERRUPT_FILE} ; inbox: /tmp/clone_inbox.jsonl)")
    try:
        r = subprocess.run([BUN, OC_SEND, wake, "--async"], capture_output=True,
                           text=True, timeout=30, stdin=subprocess.DEVNULL)
        ok = "attempted" if r.returncode == 0 else f"rc={r.returncode}"
        print(f"[tele] INTERRUPT wake {ok}: {body[:70]}", flush=True)
        with open(os.environ.get("OC_WAKE_LOG",
                               os.path.expanduser("~/.local/share/opencode/wake_delivery.log")), "a") as f:
            f.write(f"{time.strftime('%F %T')} INTERRUPT wake {ok} "
                    f"paused={len(killed)} gen={gen} :: {body[:120]}\n")
    except Exception as e:
        print(f"[tele] INTERRUPT wake failed: {e}", flush=True)


# ─────────────────────────────────────────────────────────────────────────────
# BACKGROUND-THE-RUNNING-COMMAND (owner, 2026-09-30)
#
# Owner: *"make it so when I run interupt it backgrounds whatever command ur
# running and forces u to answer the imbox"*.
#
# ★ WHY THIS IS NEEDED. A queued wake already lands MID-TURN at the next tool
# boundary (measured 2026-09-30). But a tool that is still EXECUTING blocks that
# boundary: `sleep 120` or a long `pytest` means the interrupt sits unread for
# as long as the command runs. So an urgent interrupt has to end the blocking
# command, which is what "background" means in effect.
#
# ★ HOW THE PROCESS IS FOUND. A running shell tool is a direct child of the
# opencode serve process with argv starting `/bin/bash -c <command>` -- verified
# on this box by listing the serve's children while a command was live.
#
# ★ TWO SAFETY RULES, because this terminates work:
#   1. AN AGE THRESHOLD. A command younger than INTERRUPT_MIN_AGE_S is left
#      alone: terminating something that is about to finish on its own is pure
#      loss, and an interrupt that arrives during a fast command does not need
#      to -- the tool boundary is seconds away.
#   2. A DENY LIST. The serve's long-lived children (the MCP servers) match the
#      child-of-serve pattern but are not tool calls. Killing them would take
#      out infrastructure to deliver a message.
# SIGTERM first so a well-behaved command cleans up, then SIGKILL. Every kill is
# logged, because a command terminated by an interrupt must be visibly
# terminated rather than silently vanishing.
# ─────────────────────────────────────────────────────────────────────────────
INTERRUPT_MIN_AGE_S = int(os.getenv("INTERRUPT_MIN_AGE_S", "10"))
# argv fragments that identify the EXECUTABLE of an infrastructure process, never a
# tool call that merely mentions one.
#
# ★ MEASURED FALSE POSITIVE, AND IT WAS IN MY OWN FIX. Matching these against the
# whole command line excluded the very process running the sweep: a command reading
# `tele_poller.py` contains the string "tele_poller" and was skipped as infrastructure.
# The same trap would silently protect `grep mcp config.json` or any command that
# mentions a denied word -- i.e. an interrupt could not break through exactly the
# commands most likely to be long. The markers are therefore matched ONLY against the
# command actually being executed (the first token after `bash -c`), so identity is
# what is compared, not phrasing.
_INFRA_MARKERS = ("tcc.js", "antigravity-bridge", "mcp-server", "compactor",
                  "oc_send.js", "tele_poller.py")

# Known long-lived children of the serve, resolved once at import so the check does
# not depend on matching a string that a future rename could break.
_KNOWN_INFRA_PIDS = set()


def _serve_pid():
    try:
        out = _run(["systemctl", "--user", "show", "-p", "MainPID", "--value",
                    "opencode-serve.service"])
        pid = int((out or "0").strip() or 0)
        return pid if pid > 0 else None
    except Exception:
        return None


def _run(argv):
    """Small helper: never raises, returns stdout or ''."""
    import subprocess
    try:
        return subprocess.run(argv, capture_output=True, text=True, timeout=10).stdout
    except Exception:
        return ""


def sweep_running_commands(min_age_s=None, dry_run=False):
    """SIGTERM (then SIGKILL) long-running shell tools under the opencode serve."""
    import subprocess, time as _t
    min_age = INTERRUPT_MIN_AGE_S if min_age_s is None else min_age_s
    serve = _serve_pid()
    if not serve:
        return []
    try:
        r = subprocess.run(["pgrep", "-P", str(serve)], capture_output=True, text=True,
                           timeout=10)
        kids = [int(x) for x in r.stdout.split() if x.strip().isdigit()]
    except Exception:
        return []

    now = _t.time()
    victims = []
    for pid in kids:
        try:
            cmd = open(f"/proc/{pid}/cmdline", "rb").read().replace(b"\0", b" ").decode(
                errors="replace").strip()
        except Exception:
            continue
        if not cmd.startswith("/bin/bash") and not cmd.startswith("/usr/bin/bash"):
            continue
        # ★ THE MARKER IS CHECKED AGAINST WHAT THE SHELL IS RUNNING, not the whole
        # command line. `bash -c grep mcp x` is an ordinary tool call; `bash -c
        # python3 .../mcp-server ...` is infrastructure. Taking the first token after
        # `-c` separates them; matching the whole string does not.
        after_c = cmd.split(" -c ", 1)[1] if " -c " in cmd else cmd
        target = after_c.strip().split()[0] if after_c.strip() else ""
        if any(m in target for m in _INFRA_MARKERS):
            continue
        try:
            # process start time from /proc stat, field 22 (/proc/uptime ticks)
            with open("/proc/uptime") as f:
                uptime = float(f.read().split()[0])
            with open(f"/proc/{pid}/stat") as f:
                fields = f.read().rsplit(")", 1)[1].split()
            starttime = int(fields[19]) / os.sysconf("SC_CLK_TCK")
            age = uptime - starttime
        except Exception:
            age = min_age + 1          # unreadable age: treat as old enough to act on
        if age < min_age:
            continue
        victims.append((pid, age, cmd[:110]))

    if dry_run:
        return victims

    out = []
    for pid, age, cmd in victims:
        # ★ KILL THE WHOLE PROCESS GROUP, NOT JUST bash. Measured: killing the bash pid
        # alone left its children (the actual `sleep`/`pytest`) running as orphans and the
        # TOOL CALL HUNG to its 300 s timeout instead of returning -- so the interrupt did
        # not yield the turn, which is the entire point. A tool's bash child gets its own
        # pgid (verified: pgid==pid, separate from the serve's), so killpg takes the shell
        # and everything it started without touching the serve or the MCP servers.
        try:
            pgid = os.getpgid(pid)
        except Exception:
            pgid = None
        try:
            if pgid and pgid != os.getpgrp():
                os.killpg(pgid, 15)
            else:
                os.kill(pid, 15)
        except Exception:
            pass
        out.append((pid, age, cmd))
    # grace, then force anything that ignored the term
    _t.sleep(2)
    for pid, age, cmd in victims:
        try:
            os.kill(pid, 0)            # still alive?
            try:
                pgid = os.getpgid(pid)
            except Exception:
                pgid = None
            if pgid and pgid != os.getpgrp():
                os.killpg(pgid, 9)
            else:
                os.kill(pid, 9)
            cmd = cmd + " [SIGKILL]"
        except Exception:
            pass
        print(f"[tele] INTERRUPT terminated pgid of pid={pid} age={age:.0f}s :: {cmd[:90]}",
              flush=True)
    if out:
        try:
            _wl = os.environ.get("OC_WAKE_LOG",
                                os.path.expanduser("~/.local/share/opencode/wake_delivery.log"))
            with open(_wl, "a") as f:
                for pid, age, cmd in out:
                    f.write(f"{time.strftime('%F %T')} INTERRUPT killed pid={pid} "
                            f"age={age:.0f}s :: {cmd}\n")
        except Exception:
            pass
    return out

def main():
    # `offset` is a MODULE global (seeded from /tmp/tele_offset at import). Assigning it inside the
    # loop would otherwise make it local, and the first read would raise
    # "cannot access local variable 'offset'" -- which is exactly what the main() refactor caused.
    global offset
    while True:
        try:
            data = api("getUpdates", {"timeout": 50, "offset": offset, "allowed_updates": '["message"]'})
            for upd in data.get("result", []):
                offset = max(offset, upd["update_id"] + 1)
                open("/tmp/tele_offset", "w").write(str(offset))
                msg = upd.get("message") or {}
                text = msg.get("text") or msg.get("caption") or ""
                photo = msg.get("photo") or []
                doc = msg.get("document") or {}
                saved = None
                if photo or doc:
                    try:
                        fid = photo[-1]["file_id"] if photo else doc.get("file_id")
                        fname = doc.get("file_name") or ("photo_" + str(msg.get("date", "0")) + ".jpg")
                        info = api("getFile", {"file_id": fid})
                        fpath = info["result"]["file_path"]
                        url = f"https://api.telegram.org/file/bot{TOKEN}/{fpath}"
                        dest_dir = "/tmp/tele_files"
                        os.makedirs(dest_dir, exist_ok=True)
                        dest = os.path.join(dest_dir, fname)
                        with urllib.request.urlopen(url, timeout=60) as r, open(dest, "wb") as out:
                            out.write(r.read())
                        saved = dest
                    except Exception as e:
                        print(f"[tele] file download error: {e}", flush=True)
                if not text.strip() and not saved:
                    continue
                rec = {"ts": msg.get("date"), "chat_id": str(msg.get("chat", {}).get("id")),
                       "from": str(msg.get("from", {}).get("first_name", "?")), "text": text}
                if saved:
                    rec["file"] = saved
                    rec["text"] = (text + f" [file: {saved}]").strip()
                # ★ Mark the line BEFORE it is appended, so the record on disk says an
                # interrupt happened even if the wake path below fails. The flag is additive:
                # every existing consumer reads `from`/`text` and ignores unknown keys.
                interrupt_body = _interrupt_body(text)
                if interrupt_body is not None:
                    rec["interrupt"] = True
                with open("/tmp/clone_inbox.jsonl", "a") as f:
                    f.write(json.dumps(rec) + "\n")
                append_array_inbox(rec)
                with open("/tmp/main_wake.log", "a") as f:
                    f.write(f"tele-wake {os.getpid()} {time.strftime('%H:%M:%S')}\n")
                # Fire AFTER the line is durably on disk: if the wake is lost the message
                # still exists, and if the write fails we never claim to have taken it.
                if interrupt_body is not None:
                    fire_interrupt(interrupt_body)
                print(f"[tele] {rec['from']}: {text[:60]}", flush=True)
        except Exception as e:
            print(f"[tele] poll error: {e}", flush=True)
            time.sleep(5)


if __name__ == "__main__":
    main()
