#!/usr/bin/env python3
"""PreToolUse guard: enforce the sister-card comment contract in Fernando: PSP.

Blocks `basecamp comments create|update` targeting the Human Card Table
(10216651629) unless the body is exactly three paragraphs (two of explanation,
one naming the next step), free of soft asks, CTAs, filler and emoji.
"""
import json, os, re, subprocess, sys, time

HUMAN_TABLE = "10216651629"
PROJECT = "48348194"
CACHE = os.path.expanduser("~/.claude/hooks/.psp-human-cards.json")
TABLE_CACHE = os.path.expanduser("~/.claude/hooks/.psp-table-columns.json")
ACCOUNT = "2914079"
TTL = 900

BANNED = [
    "say the word", "let me know", "feel free", "happy to", "if you'd like",
    "if you would like", "just let me", "would you like", "shall i",
    "want me to", "hope this helps", "i can also", "does that work",
    "sound good", "no worries", "great question", "fair challenge",
    "at the end of the day", "it is worth noting", "it's worth noting",
    "i'd be happy", "i would be happy", "don't hesitate", "do not hesitate",
    "please note", "reach out if",
]
EMOJI = re.compile("[\U0001F000-\U0001FAFF\U00002600-\U000027BF\U00002B00-\U00002BFF️]")
NEXT_STEP = re.compile(r"\bnext step", re.I)

# Bookkeeping: sentences reporting where something was written down. The human
# card is a decision surface, not a ledger of our own process.
LEDGER = [
    (r"\brecorded (on|in|as|under)\b", "reports where something was recorded"),
    (r"\blogged (as|in|to|under)\b", "reports a ledger write"),
    (r"\b(effort|defect|ledger|time) row\b", "names an internal ledger row"),
    (r"\brows? \d{3,5}\b", "cites a ledger row number"),
    (r"\bledgers?\b", "names the ledger"),
    (r"\b(projects|defects|time)\.jsonl\b", "names a ledger file"),
    (r"\bI (have |just )?(updated|noted|appended|logged|recorded|filed)\b",
     "narrates our own bookkeeping"),
    (r"\bis (now )?(on|in) the (bot )?card\b", "reports where text was posted"),
    (r"\b(bot card|card table) (carries|now carries|has)\b",
     "reports bot-card contents"),
    (r"\bdefect (row|rows)\b", "names defect rows"),
    # Process-state narration: sentences whose subject is one of our own phases or
    # artifacts rather than the reader's problem. Three of these have reached the
    # human card (rows 3808, 3877, 3908); the last passed a running guard, because
    # the patterns above catch ledger writes and row numbers and nothing else.
    (r"\b(nobody|no one) has (yet )?(designed|planned|decided|written|sized)\b",
     "narrates which phase owes the work"),
    (r"\bnot a plan\b", "narrates our phase vocabulary"),
    (r"\bis (now )?folding (it|this|them) in\b", "narrates a phase in progress"),
    (r"\b(design|intake|the battery|the build|the review) is (now )?(running|underway|in flight|folding)\b",
     "narrates a phase in progress"),
    (r"\bhas (not )?been (designed|reviewed|sized|planned)\b", "reports an artifact's phase status"),
    (r"\bgoes through (review|design|the battery)\b", "narrates our pipeline"),
    (r"\byou get back\b", "narrates what the process will hand over"),
]

# Effort accounting. The LEDGER patterns catch where a finding was FILED. They do
# not catch what a phase COST us - minutes, estimate error, finding counts, a
# phase standing as the subject of a sentence. That is our bookkeeping too, and
# it belongs on the bot card. If the cost changes what he should decide, put the
# decision in front of him instead of the arithmetic behind it.
# The one exemption: a postmortem IS the effort accounting. A comment that opens
# by declaring itself one may carry minutes, estimate error and finding counts,
# because measuring them is the whole reason it exists.
POSTMORTEM = re.compile(r"\bpost-?mortem\b", re.I)

# A second exemption: a comment Fernando asked for as a TABLE. The prose caps -
# three paragraphs, sentence and word limits, one-fact-per-sentence - describe a
# decision surface written in sentences. A table he requested is data he intends
# to act from row by row, and counting its cells as sentences would refuse the
# thing he asked for. The tone rules still apply to any prose around it.
# Fernando, 2026-08-21: "the 3 paragraph rule stays, but adding images or tables
# or bullet-points for additional explanation is allowed."
#
# So a block that is a table, a list, an image or an attachment is NOT prose. It
# does not count toward the three, and no length cap applies to it - a table row
# is not a sentence and counting its cells as words refuses the thing he asked
# for. The three prose paragraphs still have to be there and still have to obey
# every cap. The tone rules apply to everything, extras included: a metaphor
# inside a bullet is still a metaphor.
NONPROSE = re.compile(r"<(?:table|tr|td|th|ul|ol|li|figure|img|bc-attachment)\b", re.I)

ACCOUNTING = [
    (r"\b\d+\s*(?:minutes?|mins?|hours?)\b", "counts our minutes"),
    (r"\bagainst an? (?:planned|estimated?)\b", "reports estimate error"),
    (r"\b\d+\s+(?:findings?|blockers?|defects?|errata|nits?)\b", "counts our findings"),
    (r"\b(?:estimated?|priced|sized) at\b", "reports our estimate"),
    (r"\b(?:overrun|under-?ran|est\.|LOC)\b", "estimate vocabulary"),
    (r"\b(?:planning|design|intake|review|testing|postmortem|the battery)\s+"
     r"(?:cost|took|priced|produced|returned|found|caught|ran)\b",
     "a phase of ours acting as the subject"),
    (r"\bthe effort (?:now )?(?:reads|stands|costs|runs)\b", "narrates effort accounting"),
]

# Internal vocabulary. Terms that only parse if the reader has the bot card open.
JARGON = [
    (r"\bitems?\s+\d+\b", "numbered internal item"),
    (r"\bUNVERIFIED\b", "internal tracking label"),
    (r"\bverdicts?\b", "internal term"),
    (r"\bretired by\b", "internal status language"),
    (r"\bunconditional(ly)?\b", "internal status language"),
    (r"\bconditional on\b", "internal status language"),
    (r"\bdesign(ed)? intent\b", "internal term"),
    (r"\bacceptance (row|rows|ledger|criteria)\b", "internal artefact"),
    (r"\bstep \d+ of\b", "cites an internal step number"),
    (r"\b(the )?(causal )?chain\b", "internal term for the mechanism"),
    (r"\brivals?\b", "internal term"),
    (r"\bshelf survey\b", "internal artefact"),
]
# Voice. A claim about a mechanism has to say what the mechanism DOES. "The check
# cannot fail" reads two opposite ways - the check is inert, or the check must not
# fail - and the reader cannot tell which from the sentence. Name the actor and the
# action instead. Kept deliberately narrow: broad passive-voice detection fires on
# ordinary English, and an over-broad pattern costs more than the fault it catches.
VOICE = [
    (r"\b(?:can ?not|can't|could ?n[o']t|will not|won't|does not|doesn't|do not|"
     r"don't|never)\s+(?:fails?|be trusted|be relied on|catch(?:es)? anything|rejects?)\b",
     "says what it will not do instead of what it does",
     "Say the action: 'passes whatever the fuses read', 'reports every body as clean'."),
    (r"\b(?:is|are|was|were)\s+(?:not\s+)?"
     r"(?:verified|enforced|guarded|checked|covered|asserted|validated)\b(?!\s+by\b)",
     "agentless passive - nothing in the sentence does the verifying",
     "Name who or what does it: 'the workflow checks X', 'no test asserts X'."),
    (r"\bnothing\s+(?:is|was)\s+(?:done|changed|checked)\b",
     "agentless passive with no actor",
     "Name the actor and the action."),
]
# Tone. Two habits, both of them the writer showing up in a report that should
# only carry the finding.
#
# EMPHASIS: intensifiers and absolutes arranged for effect. A fact does not need
# "exactly" or "at all" to land, and a paragraph built to a reveal makes the
# reader wait for information they could have had in the first clause.
#
# EDITORIAL: sentences that judge rather than report - scoring the finding
# instead of stating it. Whether a thing was the right call is the reader's to
# decide from the facts.
EMPHASIS = [
    r"\bexactly\b", r"\bprecisely\b", r"\bat all\b", r"\boutright\b",
    r"\bthe single (?:one|thing|place|workflow|test|file)\b", r"\bthe very\b",
    r"\band nowhere else\b", r"\bnothing but\b", r"\bnot one\b",
    r"\bsimply\b", r"\bmerely\b", r"\bof course\b", r"\bobviously\b",
    r"\bentire(?:ly)?\b", r"\bwhatsoever\b", r"\bflatly\b",
]
EDITORIAL = [
    r"\bexists to (?:stop|prevent|catch|protect)\b", r"\bwhich is the point\b",
    r"\bthe whole point\b", r"\bthe real (?:cost|problem|question|answer)\b",
    r"\bworth (?:noting|knowing|saying)\b", r"\bcorrectly\b", r"\brightly\b",
    r"\btellingly\b", r"\bremarkably\b", r"\bunsurprisingly\b",
    r"\bthe right call\b", r"\bis what matters\b", r"\bneedless to say\b",
    r"\bto be fair\b", r"\bin fairness\b",
]
# Restatement. A paragraph that says one thing four ways spends the sentence
# budget on paraphrase instead of facts. Whether two sentences carry the same
# fact is semantic and a regex cannot see it - but restating an ABSENCE has a
# mechanical signature, because each paraphrase needs its own negation. Three
# negations in one paragraph is the reliable tell: "does not report", "posts no
# message", "nobody learns" are one finding wearing three coats.
NEGATION = re.compile(
    r"\b(?:not|n't|no|none|nobody|nothing|never|neither|nor|without|fails? to)\b", re.I)
MAX_PARA_NEGATIONS = 2

# Metaphor. Software does not hear, stay quiet, wake up or go blind. A figure of
# speech makes the reader translate before they can act, and the translation is
# where the meaning slips. "The room stays quiet" is one word longer than "it
# posts no message" and less exact.
METAPHOR = [
    r"\b(?:stays?|went|goes|going|fell|falls?) (?:quiet|silent|dark)\b",
    r"\b(?:hears?|heard|listens?|listening) (?:about|from|to)?\b",
    r"\b(?:speaks? up|shouts?|whispers?|screams?)\b",
    r"\b(?:wakes? up|woke up|goes to sleep|asleep at)\b",
    r"\b(?:blind to|in the dark|turns? a blind eye|flies? under)\b",
    r"\b(?:under the hood|out of the box|moving parts|low-hanging)\b",
    r"\b(?:bites?|bit) (?:us|you|back)\b",
    r"\bwearing \w+ (?:coats?|hats?)\b",
]

# Named referents. "both checks" makes him ask which two. A quantified plural
# stands only when the sentence also names the things it counts.
COUNTED = re.compile(
    r"\b(?:both|either|the two|all three|all four|the three)\s+"
    r"(?:the\s+)?[a-z][a-z-]*s\b", re.I)

# The same failure with the noun supplied and the items still missing:
# "those five instrumentation parts", "the four events". He asked "what
# instrumentation parts?" within a minute of reading one. A count only
# earns its place when the comment itself enumerates what it counts, so
# this fires unless the body carries a list or the sentence introduces one.
POINTED = re.compile(
    r"\b(?:those|these|the|all)\s+"
    r"(?:two|three|four|five|six|seven|eight|nine|ten|\d{1,3})\s+"
    r"(?:[a-z][a-z-]*\s+){0,2}[a-z][a-z-]*s\b", re.I)

URL = re.compile(r"https?://\S+")
SENT = re.compile(r"[.!?]+(?:\s|$)")
TAG = re.compile(r"<[^>]+>")


# A Basecamp record link whose visible text is the URL itself. Basecamp resolves a
# pasted link to the record's name in its own composer, but posting through the API
# does not: the server only autolinks it (class="autolinked" data-behavior="truncate",
# verified by probe 2026-08-21). So the name has to be fetched and used as the anchor
# text, or the reader gets a bare id to decode.
BARE_LINK = re.compile(
    r'<a[^>]+href="(https://(?:app\.basecamp\.com|3\.basecampapi\.com)/[^"]+)"[^>]*>\s*'
    r'(?:https?://|#?\d{6,})', re.I)

MAX_TOTAL_WORDS = 200
MAX_PARA_WORDS = 90
MAX_PARA_SENTENCES = 5
MAX_SENTENCE_WORDS = 25


# Self-owned next steps. A comment that ends "none from you" or "mine, not yours"
# declares work the session still owes. The guard runs before the comment posts
# and cannot watch what happens after it, so it records the debt instead: every
# self-owned step lands in OPEN_STEPS with its card, and psp-open-steps.py lists
# what is still outstanding. Fernando should never be the thing that restarts us.
OPEN_STEPS = os.path.expanduser("~/.claude/hooks/.psp-open-steps.json")
SELF_OWNED = re.compile(
    r"next step[^.]*?\b(?:"
    r"none from you|nothing from you|mine,? not yours|is mine\b|ours\b|"
    r"none here|no action from you|not yours"
    r")", re.I)


def record_debt(card, kind, text):
    if os.environ.get("PSP_GUARD_PREVIEW"):
        return
    try:
        steps = json.load(open(OPEN_STEPS))
    except Exception:
        steps = []
    steps.append({"card": card, "kind": kind,
                  "declared": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
                  "step": " ".join(re.sub(r"<[^>]+>", " ", text).split())[:300],
                  "done": False})
    try:
        json.dump(steps, open(OPEN_STEPS, "w"), indent=2)
    except Exception:
        pass


def record_open_step(card, para):
    record_debt(card, "self-owned", para)


# A denial is not a no-op. The card was owed a comment before the check ran and
# it is still owed one after, but nothing on the card, in the thread, or in this
# store would show it -- so one turn later a blocked write is indistinguishable
# from a delivered one. That is how a direct question sat unanswered for three
# hours (defects row 4472). Every denial is recorded here as an open obligation.
def deny(reason, card=None):
    if card:
        record_debt(card, "denied", reason.split("\n")[0])
    print(json.dumps({"hookSpecificOutput": {
        "hookEventName": "PreToolUse",
        "permissionDecision": "deny",
        "permissionDecisionReason": reason}}))
    sys.exit(0)


def human_card_ids(force=False):
    try:
        st = os.stat(CACHE)
        if not force and time.time() - st.st_mtime < TTL:
            return set(json.load(open(CACHE)))
    except Exception:
        pass
    try:
        out = subprocess.run(
            ["basecamp", "cards", "list", "--project", PROJECT,
             "--card-table", HUMAN_TABLE, "-j"],
            capture_output=True, text=True, timeout=25)
        ids = [str(c["id"]) for c in (json.loads(out.stdout).get("data") or [])]
    except Exception:
        return set()
    try:
        json.dump(ids, open(CACHE, "w"))
    except Exception:
        pass
    return set(ids)


def comment_parent(cid):
    url = f"https://3.basecampapi.com/2914079/buckets/{PROJECT}/comments/{cid}.json"
    try:
        out = subprocess.run(["basecamp", "show", url, "-j"],
                             capture_output=True, text=True, timeout=20)
        return str(((json.loads(out.stdout).get("data") or {}).get("parent") or {}).get("id") or "")
    except Exception:
        return ""


def designated_cards():
    """Cards ruled human-facing outside the Human Card Table.

    An effort can be run with a board card as its own human surface — Fernando
    ruled one that way on 2026-08-19 — and the contract has to follow the role,
    not the table. Without this the guard silently stops applying the moment the
    surface moves, which is the condition that let nine unchecked comments out
    earlier the same day.
    """
    path = os.path.join(os.path.dirname(os.path.realpath(__file__)),
                        "psp-human-cards.json")
    try:
        return {str(c["id"]): c.get("bucket", PROJECT)
                for c in json.load(open(path)).get("cards", [])}
    except Exception:
        return {}


def designated_tables():
    """Whole card tables whose cards are human-facing.

    The per-card list above stops scaling the moment a board is watched
    wholesale: the intake agent appends each card it adopts, and a card it
    forgets to append is a card the contract silently stops covering — the same
    failure the per-card list was itself added to close. A table entry is the
    backstop: every card on that board is gated whether or not anything
    remembered to list it.
    """
    path = os.path.join(os.path.dirname(os.path.realpath(__file__)),
                        "psp-human-cards.json")
    try:
        return [(str(t["id"]), str(t.get("bucket", PROJECT)))
                for t in json.load(open(path)).get("tables", [])]
    except Exception:
        return []


def cache_read(path):
    try:
        if time.time() - os.stat(path).st_mtime < TTL:
            return json.load(open(path))
    except Exception:
        pass
    return {}


def cache_write(path, data):
    try:
        json.dump(data, open(path, "w"))
    except Exception:
        pass


def table_column_ids(table, bucket):
    key = f"{bucket}:{table}"
    cache = cache_read(TABLE_CACHE)
    if key in cache:
        return set(cache[key])
    try:
        out = subprocess.run(
            ["basecamp", "cards", "columns", "--project", bucket,
             "--card-table", table, "-j"],
            capture_output=True, text=True, timeout=25)
        ids = [str(c["id"]) for c in (json.loads(out.stdout).get("data") or [])]
    except Exception:
        return set()
    cache[key] = ids
    cache_write(TABLE_CACHE, cache)
    return set(ids)


def card_column_id(cid, bucket):
    """A card's parent is its column, so the board is one hop up from the card.

    Reversing that hop — resolving the table's columns once and matching against
    the set — costs one cached call instead of one call per card.
    """
    url = (f"https://3.basecampapi.com/{ACCOUNT}/buckets/{bucket}"
           f"/card_tables/cards/{cid}.json")
    try:
        out = subprocess.run(["basecamp", "show", url, "-j"],
                             capture_output=True, text=True, timeout=20)
        return str(((json.loads(out.stdout).get("data") or {}).get("parent") or {}).get("id") or "")
    except Exception:
        return ""


def named_project(cmd):
    """The numeric project the command targets, when it states one.

    Resolving an unknown card id costs two API hops, and paying them on every
    comment posted anywhere is the difference between a hook you keep and one you
    disable. A command that names a project other than a designated bucket cannot
    be landing on a designated table, so it can skip the lookup. A command that
    names none still pays — silently skipping the check is the failure this file
    exists to prevent.
    """
    m = re.search(r"--(?:project|in)\s+[\"']?(\d+)", cmd)
    return m.group(1) if m else ""


def in_designated_table(tid, cmd=""):
    named = named_project(cmd)

    for table, bucket in designated_tables():
        if named and named != bucket:
            continue
        columns = table_column_ids(table, bucket)
        if not columns:
            continue
        if card_column_id(tid, bucket) in columns:
            return True
        parent = comment_parent_in(tid, bucket)
        if parent and card_column_id(parent, bucket) in columns:
            return True
    return False


def comment_parent_in(cid, bucket):
    url = f"https://3.basecampapi.com/2914079/buckets/{bucket}/comments/{cid}.json"
    try:
        out = subprocess.run(["basecamp", "show", url, "-j"],
                             capture_output=True, text=True, timeout=20)
        return str(((json.loads(out.stdout).get("data") or {}).get("parent") or {}).get("id") or "")
    except Exception:
        return ""


def targets_human_table(target, cmd=""):
    tid = re.sub(r".*/", "", target.split("#")[0]).replace(".json", "")
    if not tid.isdigit():
        return False
    designated = designated_cards()
    if tid in designated:
        return True
    ids = human_card_ids()
    if tid in ids or tid in human_card_ids(force=True):
        return True
    parent = comment_parent(tid)
    if parent and parent in human_card_ids():
        return True
    # A designated card lives on another board, so its comments must be resolved
    # in that bucket rather than in the PSP project.
    for card, bucket in designated.items():
        if bucket != PROJECT and comment_parent_in(tid, bucket) == card:
            return True
    return in_designated_table(tid, cmd)


def paragraphs(cmd):
    # Only the segment feeding the comment is prose. Anything after the pipe into
    # `basecamp` is shell plumbing, and quoted tokens there (e.g. d.get('ok') in a
    # trailing python3 -c) would otherwise be counted as body text.
    m = re.search(r"\|\s*basecamp\s+comments\s+(?:create|update)", cmd)
    body_cmd = cmd[:m.start()] if m else cmd
    quoted = re.findall(r"'((?:[^'])*)'", body_cmd)
    lines, seen_fmt = [], False
    for q in quoted:
        if not seen_fmt and q in ("%s\\n", "%s\n"):
            seen_fmt = True
            continue
        if seen_fmt:
            lines.append(q)
    if not lines:
        return heredoc_or_file_body(cmd)
    blocks, cur = [], []
    for l in lines:
        if l.strip() == "":
            if cur:
                blocks.append(" ".join(cur)); cur = []
        else:
            cur.append(l)
    if cur:
        blocks.append(" ".join(cur))
    return blocks


def heredoc_or_file_body(cmd):
    """Bodies that do not arrive as printf arguments.

    The guard read only `printf '%s\\n' ... | basecamp comments create`. A body
    written by heredoc and posted with `< file` or `-` extracted nothing, so
    `main` exited 0 and the comment went unchecked: six comments posted that way
    in one session were never seen by this hook (defects 2026-08-19). PreToolUse
    runs before the command does, so a file the same command is about to write
    does not exist yet — but its heredoc text is right there in the command.
    """
    blocks = []
    for body in re.findall(r"<<-?\s*['\"]?(\w+)['\"]?\n(.*?)\n\1", cmd, re.S):
        blocks.append(body[1])
    if not blocks:
        for path in re.findall(r"(?:<|\$\(cat\s+)\s*([^\s;|)<>]+)", cmd):
            expanded = os.path.expanduser(path)
            if os.path.isfile(expanded):
                try:
                    blocks.append(open(expanded).read())
                except OSError:
                    pass
    out = []
    for text in blocks:
        for para in re.split(r"\n\s*\n", text.strip()):
            if para.strip():
                out.append(" ".join(para.split()))
    return out


def main():
    payload = json.load(sys.stdin)
    if payload.get("tool_name") != "Bash":
        sys.exit(0)
    cmd = (payload.get("tool_input") or {}).get("command", "")
    if not re.search(r"basecamp\s+comments\s+(create|update)", cmd):
        sys.exit(0)
    m = re.search(r"basecamp\s+comments\s+(?:create|update)\s+(\S+)", cmd)
    if not m:
        sys.exit(0)
    card = m.group(1).strip("\"'")
    if not targets_human_table(card, cmd):
        sys.exit(0)

    paras = paragraphs(cmd)
    if not paras:
        deny("the comment body could not be read from this command, so the contract "
             "could not be checked, and an unreadable body is not an exempt one. "
             "Post it in a form this guard can read: a heredoc written in the same "
             "command, a file that already exists on disk, or "
             "printf '%s\\n' 'para' '' 'para' | basecamp comments create <id> -",
             card=card)
    text = "\n".join(paras)

    problems = []
    prose = [p for p in paras if not NONPROSE.search(p)]
    extras = len(paras) - len(prose)
    if len(prose) != 3:
        problems.append(f"{len(prose)} prose paragraphs; the contract requires exactly 3 "
                        "(two of explanation, one of next steps). Tables, lists and "
                        f"images are additional and do not count — {extras} found.")
    low = text.lower()
    hits = [b for b in BANNED if b in low]
    if hits:
        problems.append("soft-ask/CTA/filler phrase(s): " + ", ".join(repr(h) for h in hits))
    if EMOJI.search(text):
        problems.append("contains emoji")
    for pat, why in JARGON:
        m_ = re.search(pat, text, re.I)
        if m_:
            problems.append(f"internal vocabulary - {why} ({m_.group(0)!r}). "
                            "It only parses with the bot card open. Say the thing "
                            "in the reader's own terms.")
    for pat, why in (ACCOUNTING if not POSTMORTEM.search(paras[0]) else []):
        m_ = re.search(pat, text, re.I)
        if m_:
            problems.append(f"effort accounting - {why} ({m_.group(0)!r}). What a phase "
                            "cost us is bot-card material. If the cost changes his "
                            "decision, give him the decision, not the arithmetic.")

    for pat, why in LEDGER:
        m_ = re.search(pat, text, re.I)
        if m_:
            problems.append(f"bookkeeping sentence - {why} ({m_.group(0)!r}). "
                            "The human card is a decision surface, not a ledger of "
                            "our process. State the finding, not where it was filed.")
    for m_ in BARE_LINK.finditer(text):
        problems.append(
            f"link shows its URL instead of the record's name ({m_.group(1)[:60]}...). "
            "Basecamp resolves a pasted link in its own composer; posting through the "
            "API does not, so fetch the target's title and use it as the anchor text.")

    for i, para in enumerate(prose, 1):
        negs = NEGATION.findall(TAG.sub(" ", URL.sub("", para)))
        if len(negs) > MAX_PARA_NEGATIONS:
            problems.append(
                f"paragraph {i} negates {len(negs)} times ({', '.join(repr(n) for n in negs[:4])}). "
                "Restating one absence in different words spends sentences without "
                "adding facts. Say it goes missing once, then say what follows from it.")

    for pat in METAPHOR:
        m_ = re.search(pat, text, re.I)
        if m_:
            problems.append(f"metaphor ({m_.group(0)!r}). Software does not hear or "
                            "stay quiet. Say the literal thing it does or does not do.")

    enumerates = "<li" in text or "<td" in text
    for sent in re.split(r"(?<=[.;])\s+", TAG.sub(" ", text)):
        m_ = COUNTED.search(sent)
        if m_ and "`" not in sent and "<code" not in sent:
            problems.append(f"counted but unnamed ({m_.group(0)!r}). Name the things "
                            "you are counting, or he has to go and look them up.")
            break

    if not enumerates:
        for sent in re.split(r"(?<=[.;:])\s+", TAG.sub(" ", text)):
            m_ = POINTED.search(sent)
            if m_ and ":" not in sent and "`" not in sent:
                problems.append(
                    f"points at a list he cannot see ({m_.group(0)!r}). A count "
                    "with no enumeration makes him ask what they are. Name them, "
                    "list them, or say the one that matters and drop the number.")
                break

    for pat in EMPHASIS:
        m_ = re.search(pat, text, re.I)
        if m_:
            problems.append(f"emphasis written for effect ({m_.group(0)!r}). "
                            "State the fact without the intensifier; if it needs one "
                            "to land, the fact is not carrying its own weight.")
    for pat in EDITORIAL:
        m_ = re.search(pat, text, re.I)
        if m_:
            problems.append(f"editorial - judges instead of reporting ({m_.group(0)!r}). "
                            "Report the finding and let him judge it.")

    for pat, why, fix in VOICE:
        m_ = re.search(pat, text, re.I)
        if m_:
            problems.append(f"passive or ambiguous about the action - {why} "
                            f"({m_.group(0)!r}). {fix}")

    if prose and not NEXT_STEP.search(prose[-1]):
        problems.append("final paragraph does not state a next step "
                        "(it must contain 'Next step')")

    # Length. URLs are proof, not prose, so they do not count toward it.
    def wc(s):
        # Markup is not prose. Before the mark wrapper this cost nothing; with it
        # the style attribute alone would eat a dozen words of a 150-word budget.
        return len(TAG.sub(" ", URL.sub("", s)).split())

    per = [wc(p) for p in prose]
    total = sum(per)
    if total > MAX_TOTAL_WORDS:
        problems.append(f"{total} words, cap is {MAX_TOTAL_WORDS} "
                        f"(per paragraph: {per}). URLs are not counted. "
                        "Cut claims and move them to the bot card; do not cut "
                        "connective tissue.")
    for i, n_ in enumerate(per, 1):
        if n_ > MAX_PARA_WORDS:
            problems.append(f"paragraph {i} is {n_} words, cap is {MAX_PARA_WORDS}")
    for i, para in enumerate(prose, 1):
        stripped = URL.sub("", para)
        sents = [s for s in SENT.split(TAG.sub(" ", stripped)) if s.strip()]
        if len(sents) > MAX_PARA_SENTENCES:
            problems.append(f"paragraph {i} has {len(sents)} sentences, "
                            f"cap is {MAX_PARA_SENTENCES}")
        for s in sents:
            if len(s.split()) > MAX_SENTENCE_WORDS:
                problems.append(f"a sentence in paragraph {i} runs "
                                f"{len(s.split())} words, cap is {MAX_SENTENCE_WORDS}")
                break

    if SELF_OWNED.search(paras[-1]):
        record_open_step(card, paras[-1])

    if problems:
        deny("Sister-card comment contract violated:\n- " + "\n- ".join(problems) +
             "\n\nContract lives in basecamp-connect SKILL.md. Three paragraphs: two of "
             "explanation, one naming the next step, who owns it and what it unblocks. "
             "Record links carry the record's name, not its URL. "
             "Every claim about a mechanism names the actor and the action - never "
             "what it will not do. "
             "No emphasis written for effect and no editorial - report the finding, "
             "do not score it. Every sentence carries a fact the previous one did not; "
             "no paragraph restates itself. No metaphors, and anything counted is "
             "also named. No effort accounting - minutes, estimate error and finding "
             "counts belong on the bot card, unless the comment is a postmortem. "
             "Stripped-down directive register - no CTA, no soft ask, no filler. "
             "Tables, bullet lists and images are welcome as extra explanation and "
             "are exempt from the caps, but the three prose paragraphs still stand. "
             "Every factual claim carries a clickable GitHub or Basecamp link.",
             card=card)
    sys.exit(0)


if __name__ == "__main__":
    main()
