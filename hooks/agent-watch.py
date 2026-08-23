#!/usr/bin/env python3
"""List dispatched agents whose transcript ends in a death rather than a result.

A finishing agent and a dying agent produce the same notification shape in the
front thread: both say the agent stopped, and only the body tells them apart. So
eight agents hit the session limit on 2026-08-21 and none was restarted, two of
them carrying work Fernando had asked for by name (defects row 4513). Nothing
watched for it, and the front thread's memory said they had been resumed.

This reads the transcripts instead of remembering them.

Death is not the only way work stops. A build agent on Fernando's top-priority
effort polled `until HEAD changes` against a worktree only it could commit to,
and span for 53 minutes emitting no transcript records at all -- no marker, no
error, nothing for the death check to see. A wedged agent and a working one look
identical from outside; the only signal is that the transcript stopped growing.
So staleness is a state here too (defects row 4532).

  agent-watch.py                 dead or stalled agents nobody has acknowledged
  agent-watch.py --all           every agent, with its state
  agent-watch.py --ack ID [ID..] mark one handled (restarted, cleared, dropped)
  agent-watch.py --stale MINUTES silence that counts as stalled (default 20)
  agent-watch.py --dir PATH      a specific session's tasks directory
"""
import calendar, glob, json, os, re, sys, time

SESSIONS = "/private/tmp/claude-501/-Users-fernando-on-call-bot"
AGENT = re.compile(r"/(a[0-9a-f]{16})\.output$")
# Death is read from the LAST RECORD'S SHAPE, never from the words in it. The
# harness stamps isApiErrorMessage on the record it writes when it stops an
# agent; a transcript that finished ends on an ordinary assistant message.
#
# Grepping the tail for "hit your session limit" or "API error" cannot work here,
# because this fleet's whole subject matter is agent deaths: an agent that reads
# defects row 4513, or this very file, or writes a report containing the words
# "API error", matches its own detector. It produced two false positives out of
# nine on first use -- including the agent validating this script, mid-run -- and
# I restarted two agents that had in fact completed.
DEAD_MARKER = "isApiErrorMessage"
# A user interrupt writes no marker at all: the last record is plain text saying
# the request was interrupted. So the death check missed it, and the stall check
# missed it too, because that keys on an unanswered tool call and an interrupted
# agent's last record is text. Both blind to the same stop.
INTERRUPTED = "[Request interrupted by user]"
# The shapes above are the stops seen so far, which is the trap this file keeps
# falling into: each revision has detected the specific stop just witnessed. The
# catch-all below reports absence of progress alone, with no claim about why,
# because the next stop mode will have a shape nobody has seen yet.
#
# It cannot tell a finished agent from an abandoned one -- both stop writing --
# and no reading of the transcript ever will, because the difference is whether
# anyone is still waiting on it. Only the dispatcher knows that. So the tool
# reports every stop and `--ack` is where that knowledge is recorded; a finished
# agent is acknowledged once and stays quiet, and anything unacknowledged is
# something nobody has accounted for.
IDLE_HOURS = 2
# Long silences are normal for an agent inside one slow command -- a package
# resolve, a simulator boot, a full suite. The threshold is set above those and
# below "nobody would leave this alone", and the report says how long it has been
# rather than only that it crossed a line.
STALE_MINUTES = 20


def tasks_dir(argv):
    if "--dir" in argv:
        return argv[argv.index("--dir") + 1]
    runs = sorted(glob.glob(os.path.join(SESSIONS, "*", "tasks")),
                  key=os.path.getmtime, reverse=True)
    return runs[0] if runs else None


def acks(path, write=None):
    store = os.path.join(path, ".agent-watch-acked.json")
    if write is not None:
        json.dump(sorted(write), open(store, "w"), indent=2)
        return write
    try:
        return set(json.load(open(store)))
    except Exception:
        return set()


def label(path):
    try:
        first = open(path, encoding="utf-8", errors="replace").readline()
        content = json.loads(first)["message"]["content"]
        if isinstance(content, list):
            content = " ".join(c.get("text", "") for c in content if isinstance(c, dict))
        return " ".join(str(content).split())[:88]
    except Exception:
        return "(unreadable)"


# Silence alone means nothing: a transcript that finished stops growing exactly
# like one that wedged, and every completed agent in the directory is quiet
# forever. What separates them is the LAST RECORD. An agent waiting on a tool
# call ends on an assistant message carrying a tool_use with no tool_result after
# it; an agent that finished ends on its final text. A first cut of this check
# keyed on silence alone and reported two hundred long-finished agents as
# stalled, which is worse than not checking -- a report nobody can read is a
# report nobody reads.
def interrupted(record):
    content = record.get("message", {}).get("content")
    parts = content if isinstance(content, list) else [{"text": content}]
    return any(INTERRUPTED in str(p.get("text") or "") for p in parts if isinstance(p, dict))


def awaiting_tool(path):
    record = last_record(path)
    if record.get("type") != "assistant":
        return False
    content = record.get("message", {}).get("content")
    if not isinstance(content, list):
        return False
    return any(isinstance(part, dict) and part.get("type") == "tool_use"
               for part in content)


# The file's own mtime is not a clock here. A live agent's transcript grew by 45
# records while stat still reported a modification time 74 minutes old, so a
# working agent read as long-silent and a genuinely wedged one would have read
# the same. Every record carries its own ISO timestamp; that is the clock.
def last_activity(record, path):
    stamp = record.get("timestamp")
    if isinstance(stamp, str):
        try:
            return calendar.timegm(time.strptime(stamp[:19], "%Y-%m-%dT%H:%M:%S"))
        except ValueError:
            pass
    return os.path.getmtime(path)


def last_record(path):
    last = None
    with open(path, encoding="utf-8", errors="replace") as f:
        for line in f:
            if line.strip():
                last = line
    if last is None:
        return {}
    try:
        return json.loads(last)
    except ValueError:
        return {}


# A promise gated on "when the agents are done" has nowhere to live but a
# session's memory, and tonight is a catalogue of what that costs. The gate
# announces itself here, where the answer to "are they done" is already being
# printed.
PENDING = os.path.expanduser("~/on-call-bot/PENDING.md")


def pending():
    if not os.path.isfile(PENDING):
        return
    items = [l for l in open(PENDING) if l.startswith("## ")]
    if items:
        print(f"\n{len(items)} thing(s) owed in {PENDING}:")
        for line in items:
            print("   " + line[3:].strip())


def main():
    argv = sys.argv[1:]
    path = tasks_dir(argv)
    if not path or not os.path.isdir(path):
        print("no tasks directory found"); return 2

    handled = acks(path)
    if "--ack" in argv:
        ids = [a for a in argv[argv.index("--ack") + 1:] if not a.startswith("-")]
        acks(path, handled | set(ids))
        print(f"acknowledged {len(ids)}: {' '.join(ids)}")
        return 0

    rows = []
    for f in glob.glob(os.path.join(path, "a*.output")):
        m = AGENT.search(f)
        if not m:
            continue
        agent = m.group(1)
        record = last_record(f)
        dead = bool(record.get(DEAD_MARKER))
        seen = last_activity(record, f)
        quiet = (time.time() - seen) / 60
        rows.append((seen, agent, dead, agent in handled, f, quiet))

    limit = float(argv[argv.index("--stale") + 1]) if "--stale" in argv else STALE_MINUTES
    show_all = "--all" in argv
    rows.sort()
    unhandled = 0
    for mtime, agent, dead, acked, f, quiet in rows:
        # A dead transcript stops growing by definition, so staleness only means
        # something for one that never recorded a death.
        stopped = interrupted(record)
        idle = quiet >= IDLE_HOURS * 60
        stalled = not dead and (stopped or idle or (quiet >= limit and awaiting_tool(f)))
        if not show_all and not ((dead or stalled) and not acked):
            continue
        state = ("DEAD" if dead else
                 "INTERRUPTED" if stopped else
                 "IDLE" if idle else
                 "STALLED" if stalled else "ok")
        if (dead or stalled) and acked:
            state = state.lower() + "/acked"
        elif dead or stalled:
            unhandled += 1
        note = f"  quiet {quiet:.0f}m" if stalled else ""
        print(f"[{state:11}] {time.strftime('%m-%d %H:%M', time.localtime(mtime))}  "
              f"{agent}{note}\n               {label(f)}")

    if not rows:
        print("no agent transcripts in", path)
    elif unhandled:
        print(f"\n{unhandled} agent(s) stopped or went quiet without a result. "
              f"A stalled agent may be inside one slow command -- check what it is "
              f"waiting on before restarting it.")
    elif not show_all:
        print(f"no unacknowledged deaths, and nothing waiting on a tool call "
              f"for {limit:.0f}+ minutes")
        pending()
    return 1 if unhandled else 0


if __name__ == "__main__":
    sys.exit(main())
