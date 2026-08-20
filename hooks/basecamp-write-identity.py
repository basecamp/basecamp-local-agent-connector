#!/usr/bin/env python3
"""Deny any Basecamp write that does not name the identity it writes as.

The CLI's default profile is Fernando's account. Every agent instruction says
"every write uses --profile on-call-bot", and on 2026-08-19 forty-eight
bot-card comments went out under his byline anyway, across four efforts, because
one omitted flag is invisible at the call site and the API answers ok either way.

The record is what makes a ruling of his distinguishable from an agent's
reasoning, and that distinction is the thing the whole two-table scheme exists to
protect. So the fix is not another sentence in an agent file — it is that a write
without an explicit identity does not happen.

Passing `--profile default` is accepted: writing as himself is legitimate, and
saying so is the point.
"""
import json
import re
import sys

WRITE = re.compile(
    r"\bbasecamp\s+(?:"
    r"comments?\s+(?:create|update|delete)"
    r"|cards?\s+(?:create|update|move|archive|trash|done|step)"
    r"|chat\s+post"
    r"|messages?\s+(?:create|update)"
    r"|todos?\s+(?:create|update|complete)"
    r"|documents?\s+(?:create|update)"
    r"|recordings?\s+(?:archive|trash|restore)"
    r"|boosts?\s+create"
    r")\b"
)


def main():
    payload = json.load(sys.stdin)
    if payload.get("tool_name") != "Bash":
        sys.exit(0)
    cmd = (payload.get("tool_input") or {}).get("command", "")
    if not WRITE.search(cmd):
        sys.exit(0)
    if re.search(r"--profile[= ]", cmd):
        sys.exit(0)
    print(json.dumps({"hookSpecificOutput": {
        "hookEventName": "PreToolUse",
        "permissionDecision": "deny",
        "permissionDecisionReason": (
            "This Basecamp write names no identity, so it would post as the CLI's "
            "default profile — Fernando's own account. Forty-eight agent-written "
            "bot-card comments went out under his byline on 2026-08-19 this way, "
            "which makes his rulings indistinguishable from an agent's reasoning "
            "in the record.\n\n"
            "Add `--profile on-call-bot` to write as the bot, or `--profile default` "
            "if writing as Fernando is genuinely intended. Either is fine; leaving "
            "it unsaid is not."),
    }}))
    sys.exit(0)


main()
