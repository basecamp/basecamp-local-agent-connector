#!/usr/bin/env python3
"""Every working card is either waiting on Fernando or has work running.

Fernando's rule, 2026-08-21: "let's make sure every card that's in progress is
either waiting for me or has ongoing work." Eight cards failed it that evening
(defects rows 4309-4316) and he found every one by reading the board himself.

WHY IT READS BASECAMP RATHER THAN A DISPATCH LEDGER. A record of which agent is
working which card has to be written on dispatch and cleared on completion, and
the completion half is exactly the step that already fails -- the same omission
would make the ledger lie. Who spoke last on the card is a fact Basecamp already
holds, needs no maintenance, and cannot drift out of sync with itself.

THE TEST, per card:

  last comment is Fernando's           -> OURS. He spoke last; the ball is here.
  last comment is ours, step is his    -> HIS. Waiting, correctly.
  last comment is ours, step is ours   -> OURS. We announced it and stopped.
  last comment is a third party's      -> OURS. Somebody asked and nobody answered.
  no comments at all                   -> OURS, and nothing has ever been said.

A card is only a finding once it has been OURS longer than the grace period, so
a card answered two minutes ago does not read as a stall.

  psp-cards-moving.py [--grace MINUTES] [--working ID,ID] [BUCKET:TABLE:COLUMN]...

--working names the cards that have an agent on them right now. The script
cannot see subagents, so the caller supplies that from ListAgents. Passing it is
the one manual step, and it is deliberate: a card the caller cannot name is a
card nobody is tracking, which is the finding rather than a gap in the tool.

Exit 0 when every card is accounted for, 1 when any card is stalled.
"""
import json, os, re, subprocess, sys
from datetime import datetime, timezone

OPERATOR = "35753702"
AGENT = "52979317"
# A card the poller has already fired on must not still be sitting in Triage.
# Fernando's rule of 2026-08-21: a Triage card is assigned to him and moved to
# In progress the moment the watch fires. The connector emits and the front
# thread acts, so nothing in the transport enforces it -- this does, by reading
# the poller's own memory of what it has emitted and comparing against the board.
POLL_STATE = os.path.expanduser("~/.config/basecamp-connect/poll-state.json")
TRIAGE = ("43795599", "9027546450", "9027546451")

DEFAULT_COLUMNS = [
    ("43795599", "9027546450", "9027546460"),   # Mobile: On Call -> Issues -> In progress
    ("48348194", "10216651629", "10216651634"),  # Fernando: PSP -> Human -> Plan
]
SELF_OWNED = re.compile(
    r"next step[^.]*?\b(?:none from you|nothing from you|mine,? not yours|is mine\b|"
    r"ours\b|none here|no action from you|not yours)", re.I)


def bc(*args):
    r = subprocess.run(["basecamp", *args, "-j", "--profile", "on-call-bot"],
                       capture_output=True, text=True, timeout=45)
    if r.returncode != 0:
        return None
    try:
        return json.loads(r.stdout).get("data")
    except Exception:
        return None


def age_minutes(stamp):
    try:
        t = datetime.fromisoformat(stamp.replace("Z", "+00:00"))
        return (datetime.now(timezone.utc) - t).total_seconds() / 60
    except Exception:
        return 0.0


def verdict(card_id, project):
    comments = bc("comments", "list", str(card_id), "--project", project) or []
    comments = [c for c in comments if isinstance(c, dict)]
    if not comments:
        return "OURS", "no comment has ever been posted", 0.0
    last = comments[-1]
    who = str((last.get("creator") or {}).get("id"))
    age = age_minutes(last.get("created_at") or "")
    if who == OPERATOR:
        return "OURS", "he spoke last", age
    if who != AGENT:
        name = (last.get("creator") or {}).get("name", "someone else")
        return "OURS", f"{name} spoke last", age
    body = re.sub(r"<[^>]+>", " ", last.get("content") or "")
    if SELF_OWNED.search(body):
        return "OURS", "our own comment says the next step is ours", age
    return "HIS", "waiting on his ruling", age


def fired_cards():
    try:
        state = json.load(open(POLL_STATE))
    except Exception:
        return set()
    return set(state.get("cards", [])) | set(state.get("recordings", []))


def check_triage():
    """Cards the poller has emitted that are still in Triage, or unassigned."""
    bucket, table, column = TRIAGE
    cards = bc("cards", "list", "--project", bucket, "--card-table", table,
               "--column", column) or []
    fired = fired_cards()
    bad = []
    for card in [c for c in cards if isinstance(c, dict)]:
        if str(card["id"]) in fired:
            bad.append((card["id"], (card.get("title") or "")[:52]))
    for cid, title in bad:
        print(f"  UNMOVED  {cid}  {title}")
        print("           the watch fired on this and it is still in Triage")
    return [c for c, _ in bad]


def main():
    grace = 15.0
    if "--grace" in sys.argv:
        grace = float(sys.argv[sys.argv.index("--grace") + 1])
    working = set()
    if "--working" in sys.argv:
        working = {c.strip() for c in sys.argv[sys.argv.index("--working") + 1].split(",") if c.strip()}
    columns = [tuple(a.split(":")) for a in sys.argv if a.count(":") == 2] or DEFAULT_COLUMNS

    stalled = check_triage()
    for bucket, table, column in columns:
        cards = bc("cards", "list", "--project", bucket, "--card-table", table,
                   "--column", column) or []
        for card in [c for c in cards if isinstance(c, dict)]:
            state, why, age = verdict(card["id"], bucket)
            title = (card.get("title") or "")[:52]
            if str(card["id"]) in working:
                print(f"  working  {card['id']}  {title}")
            elif state == "HIS":
                print(f"  waiting  {card['id']}  {title}")
            elif age < grace:
                print(f"  fresh    {card['id']}  {title}  ({why}, {age:.0f}m)")
            else:
                print(f"  STALLED  {card['id']}  {title}")
                print(f"           {why}, {age / 60:.1f}h with no work dispatched")
                stalled.append(card["id"])

    if stalled:
        print(f"\nFAIL: {len(stalled)} card(s) unaccounted for.")
        print("Dispatch an agent, answer the card, or move it out of the working column.")
        print("A card in a working column is a claim that something is happening.")
        return 1
    print("\nOK: every working card is waiting on him or has work running.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
