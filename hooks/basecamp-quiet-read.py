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
# Quoted spans are payload, not command. A commit message that wraps so a line
# begins "basecamp constantly, so the two collide" put `basecamp` right after a
# newline -- a separator by this pattern -- and the `-q` it was matched against
# belonged to `git commit`. The deny blocked a commit that touches no Basecamp
# read at all.
QUOTED = re.compile(r"'[^']*'|\"(?:[^\"\\]|\\.)*\"", re.S)
# Only this invocation's own pipeline counts. A `-q` in a LATER command is not
# ours -- but a `-q` downstream in the same pipeline is, because `basecamp read |
# grep -q` collapses "the read failed" and "the pattern is absent" into the same
# exit code, which is the hazard this hook exists for wearing another tool's
# clothes. So `;`, `&&`, `||` and newline separate; a bare `|` does not.
SEGMENT = re.compile(r"[;&\n]|&&|\|\|")


def main():
    payload = json.load(sys.stdin)
    if payload.get("tool_name") != "Bash":
        sys.exit(0)
    cmd = (payload.get("tool_input") or {}).get("command", "")
    body = QUOTED.sub(" ", HEREDOC.sub(" ", cmd))
    quiet_read = any(BASECAMP.search(" " + segment) and QUIET.search(segment)
                     for segment in SEGMENT.split(body))
    if not quiet_read:
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
