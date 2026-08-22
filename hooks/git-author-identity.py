#!/usr/bin/env python3
"""Refuse a git commit that would not be authored by Fernando.

An agent committed to bc3-ios as `OnCallBot-Fernando-O
<fernando-oncall-bot@basecamp.com>`, leaving pull request 1621 with one commit
authored by him and two by a bot. Nothing configured that -- the clone's config
and his own earlier commit on the same branch both say
`Fernando Olivares <fernando.olivares@me.com>`. The agent passed an explicit
override, because every agent here is briefed as "acting as the Basecamp user
backed by the on-call-bot profile" and it carried that into git.

Those are two different identities. The BASECAMP POSTING identity must be the
bot: writes under Fernando's byline are what defects rows 3981 and 3984 exist
for. GIT AUTHORSHIP is his -- it is his branch, his pull request, his name on the
history. The `Co-Authored-By: Claude` trailer is where the tool gets its credit,
and it stays.

`fernando.olivares@me.com` is not an arbitrary pick: it is the dominant author
address in every repository this fleet touches -- bc3-desktop 166, hey-electron
139, hey-ios 72, core-ios 46, bc3-ios 9.
"""
import json, os, re, subprocess, sys

WANTED = "fernando.olivares@me.com"

COMMIT = re.compile(r"(?:^|[;&|(]|&&|\|\|)\s*(?:\w+=\S+\s+)*git\b[^;&|]*?\bcommit\b")
# `git -c user.email=X commit`, in either order relative to the subcommand.
DASH_C = re.compile(r"-c\s+user\.email\s*=\s*['\"]?([^'\"\s]+)")
# `--author='Name <addr>'`
AUTHOR = re.compile(r"--author\s*=?\s*['\"]([^'\"]*)['\"]|--author\s*=\s*(\S+)")
ENVVAR = re.compile(r"\bGIT_AUTHOR_EMAIL\s*=\s*['\"]?([^'\"\s]+)")
ADDRESS = re.compile(r"<([^>]+)>")
# A leading `cd <path> &&`, so the config lookup happens where the commit will.
CD = re.compile(r"(?:^|&&|;)\s*cd\s+(['\"]?)([^'\"&;|]+)\1\s*(?:&&|;)")
# Amending or rebasing someone else's commit legitimately preserves their name.
PRESERVING = re.compile(r"--reset-author|--no-edit\b.*--author|rebase|filter-branch|cherry-pick")


def deny(reason):
    print(json.dumps({"hookSpecificOutput": {
        "hookEventName": "PreToolUse",
        "permissionDecision": "deny",
        "permissionDecisionReason": reason}}))
    sys.exit(0)


def configured_email(cmd):
    target = None
    m = CD.search(cmd)
    if m:
        target = os.path.expanduser(m.group(2).strip())
    if not target or not os.path.isdir(target):
        target = os.getcwd()
    try:
        out = subprocess.run(["git", "-C", target, "config", "user.email"],
                             capture_output=True, text=True, timeout=10)
        return out.stdout.strip() or None
    except Exception:
        return None


def main():
    payload = json.load(sys.stdin)
    if payload.get("tool_name") != "Bash":
        sys.exit(0)
    cmd = (payload.get("tool_input") or {}).get("command", "")
    if not COMMIT.search(cmd):
        sys.exit(0)

    for pattern, label in ((DASH_C, "-c user.email"), (ENVVAR, "GIT_AUTHOR_EMAIL")):
        m = pattern.search(cmd)
        if m and m.group(1) != WANTED:
            deny(f"this commit would be authored {m.group(1)!r} via {label}, not {WANTED!r}. "
                 f"Git authorship is Fernando's -- it is his branch and his pull request. "
                 f"The bot identity is for BASECAMP writes only; carrying it into git is what "
                 f"left pull request 1621 with one commit his and two a bot's. Drop the "
                 f"override and let the clone's config answer, and keep the "
                 f"Co-Authored-By: Claude trailer as the record of who typed it.")

    m = AUTHOR.search(cmd)
    if m:
        value = m.group(1) or m.group(2) or ""
        found = ADDRESS.search(value)
        address = found.group(1) if found else value.strip()
        if address and address != WANTED:
            deny(f"--author names {address!r}, not {WANTED!r}. If you are re-authoring "
                 f"somebody else's commit on purpose, say so and do it outside a plain "
                 f"`git commit`. Otherwise drop --author entirely.")

    if not PRESERVING.search(cmd):
        configured = configured_email(cmd)
        if configured and configured != WANTED:
            deny(f"the repository is configured to commit as {configured!r}, not {WANTED!r}. "
                 f"That address is the dominant author in every repository this fleet "
                 f"touches. Fix the clone's config rather than overriding it per command, "
                 f"so the next commit is right without anyone remembering to pass a flag.")
    sys.exit(0)


if __name__ == "__main__":
    main()
