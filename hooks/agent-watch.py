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
import glob, json, os, re, sys, time

SESSIONS = "/private/tmp/claude-501/-Users-fernando-on-call-bot"
AGENT = re.compile(r"/(a[0-9a-f]{16})\.output$")
# A transcript that ends in one of these ended because it was stopped, not
# because the work finished. Matched against the tail only: an agent that merely
# discusses a session limit has not hit one.
DEAD = re.compile(r"terminated early|hit your session limit|hit your usage|"
                  r"API error|Delta: Agent terminated", re.I)
TAIL = 4000
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
def awaiting_tool(path):
    last = None
    with open(path, encoding="utf-8", errors="replace") as f:
        for line in f:
            if line.strip():
                last = line
    if last is None:
        return False
    try:
        record = json.loads(last)
    except ValueError:
        return False
    if record.get("type") != "assistant":
        return False
    content = record.get("message", {}).get("content")
    if not isinstance(content, list):
        return False
    return any(isinstance(part, dict) and part.get("type") == "tool_use"
               for part in content)


def tail_of(path):
    with open(path, "rb") as f:
        f.seek(0, os.SEEK_END)
        f.seek(max(0, f.tell() - TAIL))
        return f.read().decode("utf-8", "replace")


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
        agent, dead = m.group(1), bool(DEAD.search(tail_of(f)))
        quiet = (time.time() - os.path.getmtime(f)) / 60
        rows.append((os.path.getmtime(f), agent, dead, agent in handled, f, quiet))

    limit = float(argv[argv.index("--stale") + 1]) if "--stale" in argv else STALE_MINUTES
    show_all = "--all" in argv
    rows.sort()
    unhandled = 0
    for mtime, agent, dead, acked, f, quiet in rows:
        # A dead transcript stops growing by definition, so staleness only means
        # something for one that never recorded a death.
        stalled = not dead and quiet >= limit and awaiting_tool(f)
        if not show_all and not ((dead or stalled) and not acked):
            continue
        state = "DEAD" if dead else "STALLED" if stalled else "ok"
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
    return 1 if unhandled else 0


if __name__ == "__main__":
    sys.exit(main())
