#!/usr/bin/env python3
"""List dispatched agents whose transcript ends in a death rather than a result.

A finishing agent and a dying agent produce the same notification shape in the
front thread: both say the agent stopped, and only the body tells them apart. So
eight agents hit the session limit on 2026-08-21 and none was restarted, two of
them carrying work Fernando had asked for by name (defects row 4513). Nothing
watched for it, and the front thread's memory said they had been resumed.

This reads the transcripts instead of remembering them.

  agent-watch.py                 dead agents nobody has acknowledged
  agent-watch.py --all           every agent, with its state
  agent-watch.py --ack ID [ID..] mark a death handled (restarted, or dropped)
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
        rows.append((os.path.getmtime(f), agent, dead, agent in handled, f))

    show_all = "--all" in argv
    rows.sort()
    unhandled = 0
    for mtime, agent, dead, acked, f in rows:
        if not show_all and not (dead and not acked):
            continue
        state = "DEAD" if dead else "ok"
        if dead and acked:
            state = "dead/acked"
        if dead and not acked:
            unhandled += 1
        print(f"[{state:10}] {time.strftime('%m-%d %H:%M', time.localtime(mtime))}  "
              f"{agent}\n              {label(f)}")

    if not rows:
        print("no agent transcripts in", path)
    elif unhandled:
        print(f"\n{unhandled} agent(s) stopped without a result and without a restart.")
    elif not show_all:
        print("every agent death has been acknowledged")
    return 1 if unhandled else 0


if __name__ == "__main__":
    sys.exit(main())
