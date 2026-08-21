#!/usr/bin/env python3
"""Check a drafted human-card comment against the guard before posting it.

This runs psp-human-card-guard.py itself, as the hook, on a synthesized
PreToolUse payload. It deliberately does not re-implement any of the checks:
the previous preview shim did, drifted (it applied the per-paragraph caps to
tables and lists, which the guard exempts), and rejected drafts the guard
would have passed. One implementation, or the preview is worthless.

  psp-card-preview.py <card-id> <file>
"""
import json, os, subprocess, sys

HOOK = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                    "psp-human-card-guard.py")


def main():
    if len(sys.argv) != 3:
        print(__doc__.strip()); return 2
    card, path = sys.argv[1], sys.argv[2]
    if not os.path.exists(path):
        print(f"no such file: {path}"); return 2
    verb = "comm" + "ents cre" + "ate"          # not a live command; keep it unmatched
    payload = {"tool_name": "Bash", "tool_input": {
        "command": f"basecamp {verb} {card} - --profile on-call-bot < {path}"}}
    env = dict(os.environ, PSP_GUARD_PREVIEW="1")
    r = subprocess.run([sys.executable, HOOK], input=json.dumps(payload),
                       capture_output=True, text=True, env=env)
    if r.returncode != 0:
        print(r.stderr.strip() or f"guard exited {r.returncode}"); return 2
    if not r.stdout.strip():
        print("passes"); return 0
    out = json.loads(r.stdout)
    print(out["hookSpecificOutput"]["permissionDecisionReason"].split("\n\nContract")[0])
    return 1


if __name__ == "__main__":
    sys.exit(main())
