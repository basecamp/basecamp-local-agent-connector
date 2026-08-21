#!/usr/bin/env python3
"""Deny `-q` on Basecamp reads: it makes a failed read look like an empty one.

A closing verification ran `basecamp cards steps <id> ... --json -q` to confirm
eight manual Verify steps were present. The endpoint returned HTTP 500. With
`-q` the CLI emitted an empty payload instead of the error envelope, the parser
read it as an empty list, and the check printed "steps: 0 completed: 0" — one
step away from reporting the queued manual script as lost. The steps were all
there (defects row 3977).

The general shape is the one that cannot be trusted: a flag that suppresses the
error envelope makes a FAILED check indistinguishable from a PASSING check with
nothing in it. Same class as a success-shaped response against a nonexistent id
(row 3826) and a checker blind to its own input reporting zero (row 3900).

`-q` buys terser output. It costs the difference between "no results" and "the
request did not happen", which is the only thing a verification read is for.
"""
import json
import re
import sys

BASECAMP = re.compile(r"(?:^|[;&|(\n]|&&|\|\|)\s*(?:sudo\s+)?basecamp\s")
# -q as its own token, or inside a bundled short cluster like -jq. Never
# matches --quality, --queue, or a -q inside a quoted argument's interior.
QUIET = re.compile(r"(?:^|\s)-(?:[a-pr-z]*q[a-z]*)(?=\s|$)|(?:^|\s)--quiet(?=\s|$)")
HEREDOC = re.compile(r"<<-?\s*(['\"]?)(\w+)\1.*?^\s*\2\b", re.S | re.M)


def main():
    payload = json.load(sys.stdin)
    if payload.get("tool_name") != "Bash":
        sys.exit(0)
    cmd = (payload.get("tool_input") or {}).get("command", "")
    body = HEREDOC.sub(" ", cmd)
    if not BASECAMP.search(body) or not QUIET.search(body):
        sys.exit(0)
    print(json.dumps({"hookSpecificOutput": {
        "hookEventName": "PreToolUse",
        "permissionDecision": "deny",
        "permissionDecisionReason": (
            "`-q` suppresses the error envelope, so a failed Basecamp read comes "
            "back looking exactly like a successful empty one. That is how an "
            "HTTP 500 was read as \"steps: 0\" and eight manual Verify steps were "
            "nearly reported as lost (defects row 3977).\n\n"
            "Re-run without `-q` so `ok:false` survives. If the result is empty or "
            "zero, treat it as a failed read: retry, and cross-check against a "
            "second endpoint before recording it as a measurement."),
    }}))
    sys.exit(0)


main()
