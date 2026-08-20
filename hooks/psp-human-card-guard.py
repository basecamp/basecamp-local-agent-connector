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
URL = re.compile(r"https?://\S+")
SENT = re.compile(r"[.!?]+(?:\s|$)")

MAX_TOTAL_WORDS = 150
MAX_PARA_WORDS = 60
MAX_PARA_SENTENCES = 4
MAX_SENTENCE_WORDS = 40


def deny(reason):
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


def comment_parent_in(cid, bucket):
    url = f"https://3.basecampapi.com/2914079/buckets/{bucket}/comments/{cid}.json"
    try:
        out = subprocess.run(["basecamp", "show", url, "-j"],
                             capture_output=True, text=True, timeout=20)
        return str(((json.loads(out.stdout).get("data") or {}).get("parent") or {}).get("id") or "")
    except Exception:
        return ""


def targets_human_table(target):
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
    return False


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
    if not targets_human_table(m.group(1).strip("\"'")):
        sys.exit(0)

    paras = paragraphs(cmd)
    if not paras:
        deny("the comment body could not be read from this command, so the contract "
             "could not be checked, and an unreadable body is not an exempt one. "
             "Post it in a form this guard can read: a heredoc written in the same "
             "command, a file that already exists on disk, or "
             "printf '%s\\n' 'para' '' 'para' | basecamp comments create <id> -")
    text = "\n".join(paras)

    problems = []
    if len(paras) != 3:
        problems.append(f"{len(paras)} paragraphs; the contract requires exactly 3 "
                        "(two of explanation, one of next steps)")
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
    for pat, why in LEDGER:
        m_ = re.search(pat, text, re.I)
        if m_:
            problems.append(f"bookkeeping sentence - {why} ({m_.group(0)!r}). "
                            "The human card is a decision surface, not a ledger of "
                            "our process. State the finding, not where it was filed.")
    if not NEXT_STEP.search(paras[-1]):
        problems.append("final paragraph does not state a next step "
                        "(it must contain 'Next step')")

    # Length. URLs are proof, not prose, so they do not count toward it.
    def wc(s):
        return len(URL.sub("", s).split())

    per = [wc(p) for p in paras]
    total = sum(per)
    if total > MAX_TOTAL_WORDS:
        problems.append(f"{total} words, cap is {MAX_TOTAL_WORDS} "
                        f"(per paragraph: {per}). URLs are not counted. "
                        "Cut claims and move them to the bot card; do not cut "
                        "connective tissue.")
    for i, n_ in enumerate(per, 1):
        if n_ > MAX_PARA_WORDS:
            problems.append(f"paragraph {i} is {n_} words, cap is {MAX_PARA_WORDS}")
    for i, para in enumerate(paras, 1):
        stripped = URL.sub("", para)
        sents = [s for s in SENT.split(stripped) if s.strip()]
        if len(sents) > MAX_PARA_SENTENCES:
            problems.append(f"paragraph {i} has {len(sents)} sentences, "
                            f"cap is {MAX_PARA_SENTENCES}")
        for s in sents:
            if len(s.split()) > MAX_SENTENCE_WORDS:
                problems.append(f"a sentence in paragraph {i} runs "
                                f"{len(s.split())} words, cap is {MAX_SENTENCE_WORDS}")
                break

    if problems:
        deny("Sister-card comment contract violated:\n- " + "\n- ".join(problems) +
             "\n\nContract lives in basecamp-connect SKILL.md. Three paragraphs: two of "
             "explanation, one naming the next step, who owns it and what it unblocks. "
             "Stripped-down directive register - no CTA, no soft ask, no filler. "
             "Every factual claim carries a clickable GitHub or Basecamp link.")
    sys.exit(0)


if __name__ == "__main__":
    main()
