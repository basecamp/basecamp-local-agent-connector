#!/usr/bin/env python3
"""List the next steps this session declared its own and has not cleared.

A sister-card comment ending "none from you" or "mine, not yours" is a promise.
psp-human-card-guard.py records each one as it posts; nothing else watches them,
which is how Fernando ends up nudging us to start work we already announced.

  psp-open-steps.py              list what is still open
  psp-open-steps.py --done CARD  mark every open step on that card cleared
  psp-open-steps.py --all        include cleared ones
"""
import json, os, sys

PATH = os.path.expanduser("~/.claude/hooks/.psp-open-steps.json")


def load():
    try:
        return json.load(open(PATH))
    except Exception:
        return []


def main():
    steps = load()
    if "--done" in sys.argv:
        card = sys.argv[sys.argv.index("--done") + 1]
        hit = 0
        for s in steps:
            if s["card"] == card and not s["done"]:
                s["done"] = True
                hit += 1
        json.dump(steps, open(PATH, "w"), indent=2)
        print(f"cleared {hit} step(s) on card {card}")
        return 0

    show = steps if "--all" in sys.argv else [s for s in steps if not s["done"]]
    if not show:
        print("no open self-owned steps")
        return 0
    for s in show:
        mark = "done" if s["done"] else "OPEN"
        print(f"[{mark}] {s['declared']}  card {s['card']}")
        print(f"       {s['step'][:160]}")
    print(f"\n{len([s for s in show if not s['done']])} open")
    return 1 if any(not s["done"] for s in show) else 0


if __name__ == "__main__":
    sys.exit(main())
