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
# A mention expands to <bc-attachment><figure><img>…</figure></bc-attachment> and
# sits INSIDE the opening sentence. Classifying that paragraph as a picture drops
# the prose count from 3 to 2 and denies the comment: 121 of 143 real comments
# carry a mention and 120 of their denials had no other cause. Strip mentions
# before deciding what a paragraph is.
MENTION = re.compile(r"<bc-attachment\b[^>]*\bcontent-type=[\"']application/vnd\.basecamp\.mention"
                     r"[^>]*>.*?</bc-attachment>", re.I | re.S)
NONPROSE = re.compile(r"<(?:table|tr|td|th|figure|img|bc-attachment)\b", re.I)

# Bullet lists are gone. Fernando, on the voice: "Let's get rid of bullet points
# in the voice. They don't serve other purpose than to extend comments." He is
# describing what they were being used for -- a list is exempt from the word and
# sentence caps, so five bullets carry what three paragraphs are not allowed to
# say. Tables and images stay; they carry things prose genuinely cannot.
LISTS = re.compile(r"<(?:ul|ol|li)\b", re.I)

# Build artifacts, the same fault as the minutes below. The patterns here count
# what a phase COST in time; they never counted what the work TOUCHED, and
# Fernando named that on 2026-08-24: "there's no need to state files changed,
# number of tests passed." He called the passage "mostly useless" rather than
# useless, and the word is doing real work - inside the same paragraph
# "Missing those would have left Xcode pointed at 4.2.1" is a consequence he can
# act on. So this matches the COUNT, not the sentence carrying it: a sentence
# that states a consequence and happens to sit beside an inventory keeps its
# place, and only a body that actually counts our work is refused.
#
# The discriminator is the noun, never the number. "353 events and 126 users",
# "1.3.6 carries 654 users against 61 on 1.3.3" and "five events and three users
# sit under 100" measure the world and stand. "ten files", "1246 tests" and "Two
# commits" measure our own labour and do not.
#
# Three of the nouns he listed are deliberately absent, each for a measured
# reason (65 comments, the on-call cards, 22-25 August):
#
#   `lines` - fourteen sentences carry a line count and ten of them are
#   FORECASTS of work not yet done: "about seventy-five lines", "the tag is three
#   lines", "about fifty lines across three files". That number is the answer to
#   the question he is being asked - is this worth building - and refusing it
#   deletes the decision, not the bookkeeping. Hedges do not separate the two
#   ("The code fix is five lines" carries none), and keying on "about" would only
#   teach the bot to write it.
#
#   `runs` - ten of its twelve appearances are the verb ("the same write still
#   runs on the thread that draws the screen"), and the noun's one real use was
#   "two runs at once make the loser report skipped", a concurrency defect rather
#   than a count of our test passes.
#
#   `rows` - never once appears as a count in the corpus, while LEDGER already
#   refuses the ledger sense, and tables are welcome on this card by his own
#   ruling, so "five rows" is as likely to describe one of those.
NUMERAL = (r"\d[\d,]*|"
           r"(?:twenty|thirty|forty|fifty|sixty|seventy|eighty|ninety)"
           r"(?:-(?:one|two|three|four|five|six|seven|eight|nine))?|"
           r"one|two|three|four|five|six|seven|eight|nine|ten|eleven|twelve|"
           r"thirteen|fourteen|fifteen|sixteen|seventeen|eighteen|nineteen|"
           r"a dozen|dozens")
ARTIFACT = r"\w*files?|tests?|assertions?|failures?|insertions?|deletions?|commits?"
# `(?<![.\d])` keeps a version out of the count: these cards are thick with
# dotted versions AND with artifact nouns, and "the 1.34.13 tests" would
# otherwise read as thirteen of them. It is precautionary - it saves nothing in
# the 65-comment corpus, because the one sentence that needed it ("the 1.34.10
# comparison runs on identical capture settings") stopped matching when `runs`
# was dropped. Kept because the collision is one keystroke away, not because it
# was measured to fire.
#
# One adjective may sit between the count and the noun, but never a plural noun,
# which is what stops "a quarter's 1,252 events file as one issue" from reading
# as a file count. And a commit count that is a DISTANCE is a fact about the
# world, not about our labour: "seven commits behind" measures how far a pin
# lags its branch, which is true whether or not we ever touch it, so it stands
# for the same reason "654 users" does.
COUNTS_OUR_WORK = (
    r"(?<![.\d])\b(?:" + NUMERAL + r")\s+"
    r"(?:[a-z][a-z-]*(?<!s)\s+)?"
    r"(?:" + ARTIFACT + r")\b(?!\s+(?:behind|ahead|back)\b)")

ACCOUNTING = [
    (r"\b\d+\s*(?:minutes?|mins?|hours?)\b", "counts our minutes"),
    (r"\bagainst an? (?:planned|estimated?)\b", "reports estimate error"),
    (COUNTS_OUR_WORK, "counts our own work - files touched, tests run, commits made"),
    (r"\b(?:" + NUMERAL + r")\s+(?:findings?|blockers?|defects?|errata|nits?)\b",
     "counts our findings"),
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
# ORNAMENT: writerly vocabulary that carries no information. A third habit,
# next to the two above and doing a different job. EMPHASIS turns up the volume
# on a fact; EDITORIAL scores it; an ornament REPLACES it. "The follow-up is
# load-bearing" says the follow-up matters without saying what breaks without
# it, and the reader cannot act on the word. Fernando, 2026-08-24, on
# "load-bearing" - it reached the human card twice that day.
#
# A term this fleet uses with a technical meaning stays out of this list however
# writerly it looks elsewhere, because denying it would deny the only word for
# the thing: `lens` is a reviewer in the battery, `cadence` is the release
# cadence a shelf survey has to report for a layer-4 candidate, and `blast
# radius`, `single source of truth`, `mutation`, `acceptance ledger`, `fix
# ladder`, `cast` and `retreat map` are all named parts of the process.
# "at the end of the day" is not here either - BANNED already carries it, and
# one fault should be reported once.
ORNAMENT = [
    r"\bload-bearing\b", r"\bnon-trivial\b", r"\borthogonal\b",
    r"\bfirst-class\b", r"\bnorth star\b", r"\bsurface area\b",
    r"\bin anger\b", r"\bmoves? the needle\b", r"\btable stakes\b",
    r"\btexture\b", r"\belegant(?:ly)?\b", r"\bseamless(?:ly)?\b",
    r"\bmeaningfully\b", r"\bmaterially\b", r"\bfundamentally\b",
    r"\bessentially\b", r"\bcrucially\b", r"\bnotably\b",
    r"\bimportantly\b", r"\binterestingly\b", r"\barguably\b",
    # Verb forms only. The noun ("the leverage it gives us") is a different word
    # and is not what leaks.
    r"\b(?:leverages|leveraged|leveraging)\b",
    r"\b(?:can|could|will|would|should|to|we|it|they)\s+leverage\b",
    # Sentence-opening discourse marker only: "the ruling that said nothing
    # would be built" is a relative clause and is not this fault.
    r"(?:^|(?<=[.!?]\s))\s*That said\b",
    # The reading sense only. "unpack the archive" is what the word is for.
    r"\bunpack(?:s|ed|ing)?\s+(?:the\s+|that\s+|this\s+|its\s+|their\s+)?"
    r"(?:argument|reasoning|claim|idea|question|thinking|point|logic|history)\b",
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
# The counter has to be followed by a NOUN. "either goes unrecorded" and "both
# runs green" are not counted-but-unnamed, and denying them costs a round each.
# Nothing here does part-of-speech tagging, so the verbs that actually turn up
# after these counters are listed and skipped.
VERBS = (r"goes|does|is|was|has|gets|takes|makes|needs|runs|says|means|comes|"
         r"stays|keeps|lands|reads|writes|holds|sits|ships|fires|costs|counts|"
         r"matches|carries|leaves|ends|starts|stops|fails|passes|wins|looks|"
         r"points|names|calls|shows|tells|asks|wants|works|helps|adds|drops")
COUNTED = re.compile(
    r"\b(?:both|either|the two|all three|all four|the three)\s+"
    r"(?:the\s+)?(?!(?:" + VERBS + r")\b)[a-z][a-z-]*s\b", re.I)

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
CODE = re.compile(r"<code\b[^>]*>(.*?)</code>", re.I | re.S)


# The empty sentence. Fernando, 2026-08-24, quoting one of mine: "One gap this
# makes reachable, which I left alone rather than widen a reviewed branch." He
# said he would not know how to catalogue it. The sentence asserts nothing; its
# whole job is to announce that a sentence is coming, and the fact it stood in
# for (the picker never re-derives authorization on return) arrived in the NEXT
# sentence. Two faults were separable in it:
#
# (a) No finite main verb. Every verb - makes, left, widen - sits inside a
#     subordinate clause, so nothing predicates anything.
# (b) A placeholder subject. "gap" stands in for the thing instead of naming it,
#     and the sentence carries no number, no path, no identifier.
#
# ONLY (b) IS IMPLEMENTED, and (a) was built, measured and thrown away. Over the
# 53 comments this bot posted to the on-call cards on 2026-08-22 through 08-24, a
# verbless test fired 13 times and was right ONCE - on the sentence above. The
# twelve others were ordinary sentences with ordinary main verbs, and the two
# causes are not tunable:
#
#   "That page event only drives the adapter" - `that` here is a determiner, and
#   "Per hour that family went up" and "That was my error" are the same word
#   again as determiner and pronoun. Telling those from the relativizer in "the
#   check that runs" is a tagging problem.
#
#   "They name which mechanism it is", "Keep 262 anyway", "Then decide the
#   remaining fix" - bare-form main verbs. A plural present, an imperative and a
#   noun are the same string, so no word list can find the predicate; adding one
#   invents a false verb somewhere else. VERBS below works because it is asked
#   one narrow question in one narrow slot (what follows a counter), not to parse
#   a sentence.
#
# A guard nobody can satisfy gets worked around - that is how the bullet-list
# exemption happened - and 12 false denials in 53 comments is that guard. Left
# out deliberately; do not re-add it without measuring it again.
# No possessives. A possessive names an owner, which makes the noun referential
# rather than a stand-in: "My note that night predicted a different trigger" is
# a fact about a specific note and the only false denial this rule produced over
# the 53 posted comments it was measured against.
DETERMINER = (r"a|an|the|this|that|these|those|one|two|three|four|five|six|"
              r"seven|eight|nine|ten|another|each|every|some|any|no|both|"
              r"several|few|many|most|\d+")
# The nouns that stand in for the thing instead of naming it.
PLACEHOLDER = (r"gaps?|things?|points?|parts?|half|halves|pieces?|items?|"
               r"notes?|corrections?|follow-?ups?|questions?|issues?|"
               r"wrinkles?|catch(?:es)?|upshots?|takeaways?")
ANNOUNCEMENT = re.compile(
    r"^(?:" + DETERMINER + r")\s+(?:" + PLACEHOLDER + r")\b", re.I)

# What a reader can act on: a number, a quoted span, a path, an identifier, a
# proper noun. A sentence carrying none of them has named nothing, and a
# placeholder subject on top of that leaves it with nothing to say. The evidence
# half is what keeps the rule off the sentences that merely START this way -
# "Two things turned up in HEY-DESKTOP-64Q" names its subject and stands.
EVIDENCE = re.compile(
    r"\d|`[^`]+`|/[\w.-]+/|\b\w+[._]\w+\b|\b[a-z]+[A-Z]\w*\b")
PROPER = re.compile(r"\b[A-Z][A-Za-z0-9-]+")


def sentences(para):
    """The paragraph's sentences, with the markup that is not prose removed.

    Mentions go first: a mention expands to an attachment carrying a person's
    name, and reading that name as a proper noun would let every sentence
    sharing a paragraph with one claim it had named something.
    """
    text = CODE.sub(r"`\1`", MENTION.sub(" ", para))
    text = TAG.sub(" ", URL.sub(" ", text))
    return [" ".join(s.split()) for s in SENT.split(text) if s.strip()]


def names_something(sent, blind=0):
    """Whether the sentence points at anything the reader can act on.

    `blind` masks the opening determiner and placeholder without moving the rest
    of the sentence, because the count in "2 corrections to what I put here
    earlier" is part of the stand-in and not evidence of anything. Masking with
    spaces rather than slicing keeps the offsets, so a proper noun that opens the
    remainder still reads as non-initial.
    """
    sent = " " * blind + sent[blind:]
    if EVIDENCE.search(sent):
        return True
    return any(m.start() > 0 for m in PROPER.finditer(sent))


def empty_sentences(prose):
    """Sentences whose subject is a placeholder and which name nothing."""
    found = []
    for para in prose:
        for sent in sentences(para):
            if len(sent.split()) < 3:
                continue
            opener = ANNOUNCEMENT.match(sent)
            if opener and not names_something(sent, opener.end()):
                found.append(sent)
    return found


# The method preamble. Fernando, 2026-08-24, on a sentence of mine from that
# night: "I don't need meta-statements like 'Measuring the file instead of the
# culprit:'. The rest of the sentence is useful enough." A sentence-initial
# clause narrating the act of measuring or looking, handed to the finding by a
# colon or a comma. The finding stands on its own; the preamble says how we got
# it, which is our process and belongs on the bot card with the rest of it.
#
# Only the forms he listed, spelled out rather than stemmed. Bare "read" and
# "check" are deliberately absent: "Read the thread, then rule" is an imperative
# in a next-step paragraph, not a preamble, and stemming would swallow it.
INSPECTION = (r"measuring|reading|re-reading|checking|querying|queried|measured|"
              r"counting|counted|running|re-running|ran|looking|grepping|"
              r"diffing|inspecting|comparing|testing|verifying|scanning|"
              r"sampling|pulling|fetching")

# Two handoffs, held to different lengths, because they carry different risk.
#
# A colon after a sentence-initial participle is unambiguous - a gerund SUBJECT
# is never handed to a colon before its own verb - so the clause may run long.
# "Reading every event in the window instead of a sample:" is ten words and is
# the fault exactly.
#
# A comma is where the ambiguity lives, and it is the one Fernando drew a line
# around: "Running the suite serially avoids the port collision" is a claim about
# the system whose gerund is the SUBJECT, and a trailing "..., which is why we
# serialize" would otherwise pull it in. Two things keep it out - the clause must
# be short (his real one, "Queried directly,", is two words) and it must carry no
# finite verb of its own. `[^\s:,]+` stops either pattern at the first
# punctuation, so what matches is the opening clause and not some later one.
METHOD_PREAMBLE = [
    (re.compile(r"^(?:" + INSPECTION + r")\b((?:\s+[^\s:,]+){0,12})\s*:\s+(.+)$", re.I), False),
    (re.compile(r"^(?:" + INSPECTION + r")\b((?:\s+[^\s:,]+){0,4})\s*,\s+(.+)$", re.I), True),
]
# The generous -s/-ed shape again, and generous is again the safe direction: a
# plural noun misread as a verb costs a preamble we do not catch, while a real
# verb missed would deny a sentence about the system. Never applied to the
# opening word itself, which is a participle and ends that way by definition.
PREAMBLE_VERB = re.compile(
    r"\b(?:" + VERBS + r"|is|are|was|were|has|have|had|does|did|do|will|would|"
    r"can|could|should|must|may|might|\w{3,}(?:ed|s))\b", re.I)


def method_preambles(prose):
    """Sentence openings that narrate the looking instead of stating the finding."""
    found = []
    for para in prose:
        for sent in sentences(para):
            for pattern, veto in METHOD_PREAMBLE:
                m = pattern.match(sent)
                if not m:
                    continue
                if veto and PREAMBLE_VERB.search(m.group(1)):
                    continue
                # The finding after the handoff has to be able to stand alone; a
                # participial clause that IS the whole sentence is not this fault.
                if len(m.group(2).split()) < 3:
                    continue
                found.append((sent[:m.start(2)].rstrip(), m.group(2)))
                break
    return found


# A Basecamp record link whose visible text is the URL itself. Basecamp resolves a
# pasted link to the record's name in its own composer, but posting through the API
# does not: the server only autolinks it (class="autolinked" data-behavior="truncate",
# verified by probe 2026-08-21). So the name has to be fetched and used as the anchor
# text, or the reader gets a bare id to decode.
BARE_LINK = re.compile(
    r'<a[^>]+href="(https://(?:app\.basecamp\.com|3\.basecampapi\.com)/[^"]+)"[^>]*>\s*'
    r'(?:https?://|#?\d{6,})', re.I)


# A pull request or a Sentry issue named by its id carries a link. Fernando,
# 2026-08-24: "why are we not catching that all PRs should have links?", and on
# scope: "Both PRs and Sentry issues should be linked." Four PR references went
# out that evening as bare text - "Pull request 1667", "Pull request 1648",
# "PR 133", "PR 1666" - and six Sentry ids alongside them. Each one sends him to
# go and find it. The discipline had been holding only when he asked for links by
# name in the message that started the work, which is not a discipline.
#
# This is the inverse of BARE_LINK above, not a duplicate of it: that one refuses
# a link whose visible text is its own URL and demands the record's name instead,
# and this one refuses the absence of a link. They compose, and the corpus already
# carries the shape both of them want - `hey-ios#1665` as the anchor text over a
# github pull URL.
#
# Basecamp cards and comments are NOT here. He ruled on pull requests and Sentry
# issues and said nothing about ids, and the corpus says there is nothing to fix:
# all thirteen ten-digit record ids in it are already inside a link, none bare.
#
# The bare number leaning on a repo established earlier ("Your 1666 shipped a
# second one doing the same job") is deliberately NOT matched. Telling that from
# a version, an event count or a build number needs a number detector, and a
# wrong one denies arithmetic he asked for. It under-reaches by one shape, and
# that costs nothing here: the comment carrying it also says "Pull request 1667".
ANCHOR_TEXT = re.compile(r"<a\b[^>]*>.*?</a>", re.I | re.S)
HREF = re.compile(r"href=[\"']([^\"']+)[\"']", re.I)
PR_REFERENCE = re.compile(
    r"\bpull\s+requests?\s+#?(\d+)"      # pull request 1667
    r"|\bPRs?\s+#?(\d+)"                 # PR 133
    r"|\b[\w.-]+/[\w.-]+#(\d+)"          # basecamp/bc3#12863
    r"|\b[a-z][\w.-]*#(\d+)",            # hey-ios#1665
    re.I)
# Case-sensitive, and that is load-bearing rather than tidy: the bot cards in this
# fleet are named `bc3-ios-web-view-bridge-diagnostic-fires-on-live-bridges`, and
# a case-blind version of this reads `bc3-ios-web` as a Sentry short id and denies
# every comment that names its own bot card.
SENTRY_ID = re.compile(
    r"\b(?:BC3|BC4|HEY)-(?:IOS|DESKTOP|ANDROID|WEB|ELECTRON)-[A-Z0-9]{2,6}\b")
REFERENCES = [("pull request", PR_REFERENCE), ("Sentry issue", SENTRY_ID)]


def unlinked_references(text):
    """PR and Sentry references outside a link, with nothing else linking that id.

    Deliberately forgiving about WHERE the link is. A comment that links the issue
    once and then talks about it in prose has already saved him the lookup, so
    only an id nothing points at is refused. Bare URLs count as links because
    Basecamp autolinks them, and they are stripped before the scan for the same
    reason.
    """
    body = MENTION.sub(" ", text)
    outside = URL.sub(" ", TAG.sub(" ", ANCHOR_TEXT.sub(" ", body)))
    targets = " ".join(HREF.findall(body) + URL.findall(body))
    found = []
    for kind, pattern in REFERENCES:
        for m in pattern.finditer(outside):
            identifier = next((gr for gr in m.groups() if gr), m.group(0))
            if re.search(r"(?<![\w-])" + re.escape(identifier) + r"(?![\w-])", targets):
                continue
            found.append((kind, " ".join(m.group(0).split())))
    return found


# Tier one of the verifier question, and the only tier that belongs in a hook:
# the anchor text has to agree with the href it sits on. "Pull request 1667"
# pointing at /pull/1666 is a transposition no reading catches, and HEY-IOS-669
# against HEY-IOS-663 is one character. Both are offline, deterministic and cost
# nothing.
#
# Scoped to github pull/issue links and Sentry issue links, because those are the
# two whose id convention is known. A Basecamp link carries a record TITLE as its
# anchor text, and a title with a number in it ("... | May 29") would be read as a
# claim about the card id and denied.
#
# The claim is only read off the END of a github label - every one in the corpus
# is "<repo words> <number>": "Hotwire Native 262", "bc3 12863", "core-ios 133",
# "PR 1648", "hey-ios#1665". A number anywhere else in the label is describing
# something, not naming the target.
LINK_TARGETS = [
    ("pull request",
     re.compile(r"github\.com/[\w.-]+/[\w.-]+/(?:pull|issues)/(\d+)", re.I),
     lambda label: re.findall(r"#?(\d{2,})\s*$", label)),
    ("Sentry issue",
     re.compile(r"sentry\.io/issues/([A-Za-z0-9-]+)", re.I),
     lambda label: SENTRY_ID.findall(label)),
]


def mismatched_links(text):
    """Links whose visible id is not the id the href points at."""
    found = []
    for m in ANCHOR_TEXT.finditer(MENTION.sub(" ", text)):
        href = HREF.search(m.group(0))
        if not href:
            continue
        label = " ".join(TAG.sub(" ", m.group(0)).split())
        for kind, target, shown_ids in LINK_TARGETS:
            hit = target.search(href.group(1))
            if not hit:
                continue
            shown = shown_ids(label)
            if not shown:
                continue
            if any(one.upper() == hit.group(1).upper() for one in shown):
                continue
            found.append((kind, label, hit.group(1)))
            break
    return found


# Tier two: does the link's target exist. Fernando, 2026-08-24, on the offline
# check and this one together: "Ok let's try both of these solutions."
#
# It reads the HREFS ONLY, never the prose, and that is what makes it possible at
# all. "Pull request 1667" does not name a repository and could be any of ours,
# so there is nothing to ask about; the presence rule above already refuses a
# reference carrying no link, so by the time this runs every reference the reader
# can follow is a URL naming its owner, its repo and its number.
#
# GITHUB ONLY, AND NO SENTRY BRANCH THAT ALWAYS PASSES. Probed 2026-08-24: this
# environment has `gh` authenticated and answering in under a second, and for
# Sentry it has no SENTRY_AUTH_TOKEN, no sentry-cli and no ~/.sentryclirc, while
# the Sentry MCP server a session can call is not reachable from a PreToolUse
# hook at all. A check that cannot fail reads as coverage, which is worse than no
# check, so Sentry ids get the two offline tiers and nothing more.
#
# FAILS OPEN, AND LEAVES A TRACE. A 404 is an answer, and it denies. A timeout, a
# missing `gh`, a rate limit or an expired token is NOT an answer: the post goes
# through, because a hook that blocks a legitimate comment on a network blip is a
# hook that gets worked around, and every other network path in this file already
# fails open. What makes that defensible rather than theatre is the trace - the
# miss is recorded through record_debt and psp-open-steps.py lists it afterwards.
# cite-check.py reserves a third verdict for exactly this (UNRESOLVED, "silence
# would read as coverage"); a PreToolUse hook has only allow and deny, so the
# third verdict has to be written down instead of returned.
GH = os.environ.get("PSP_GUARD_GH", "gh")
VERIFIED = os.path.expanduser(os.environ.get(
    "PSP_GUARD_VERIFY_CACHE", "~/.claude/hooks/.psp-verified-refs.json"))
VERIFY_TIMEOUT = 5
VERIFY_BUDGET = 12
# `issues/N` rather than `pulls/N`: every pull request is an issue on this
# endpoint, so one call answers for both link shapes.
GH_TARGET = re.compile(
    r"github\.com/([\w.-]+)/([\w.-]+)/(?:pull|issues)/(\d+)", re.I)


def github_has(owner, repo, number, deadline):
    """True, False, or None when nothing definite came back."""
    left = deadline - time.time()
    if left <= 0:
        return None
    try:
        out = subprocess.run(
            [GH, "api", f"repos/{owner}/{repo}/issues/{number}"],
            capture_output=True, text=True, timeout=min(VERIFY_TIMEOUT, left))
    except Exception:
        return None
    if out.returncode == 0:
        return True
    if '"status":"404"' in out.stdout or "HTTP 404" in out.stderr:
        return False
    return None


def unresolvable_links(text, card=None):
    """Linked pull requests GitHub does not have. Asks the network; fails open."""
    body = MENTION.sub(" ", text)
    targets, seen = [], set()
    for href in HREF.findall(body) + URL.findall(body):
        m = GH_TARGET.search(href)
        if not m:
            continue
        key = f"{m.group(1)}/{m.group(2)}#{m.group(3)}"
        if key not in seen:
            seen.add(key)
            targets.append((key, m.group(1), m.group(2), m.group(3)))
    if not targets:
        return []
    try:
        cache = json.load(open(VERIFIED))
    except Exception:
        cache = {}
    deadline = time.time() + VERIFY_BUDGET
    missing, fresh = [], False
    for key, owner, repo, number in targets:
        if cache.get(key):
            continue
        answer = github_has(owner, repo, number, deadline)
        if answer is True:
            cache[key] = True
            fresh = True
        elif answer is False:
            missing.append(key)
        else:
            record_debt(card, "unverified-link",
                        f"could not confirm {key} exists; the comment posted "
                        "without that check")
    if fresh:
        try:
            json.dump(cache, open(VERIFIED, "w"))
        except Exception:
            pass
    return missing


MAX_TOTAL_WORDS = 180
MAX_PARA_WORDS = 90
MAX_PARA_SENTENCES = 5
MAX_SENTENCE_WORDS = 25


# Self-owned next steps. A comment that ends "none from you" or "mine, not yours"
# declares work the session still owes. The guard runs before the comment posts
# and cannot watch what happens after it, so it records the debt instead: every
# self-owned step lands in OPEN_STEPS with its card, and psp-open-steps.py lists
# what is still outstanding. Fernando should never be the thing that restarts us.
OPEN_STEPS = os.path.expanduser(os.environ.get(
    "PSP_GUARD_OPEN_STEPS", "~/.claude/hooks/.psp-open-steps.json"))
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


# One command can carry more than one heredoc. A compound that edits a draft with
# a python heredoc and then posts the draft with `< path` had the python source
# read as the comment body, and the guard denied the post with specific
# complaints about text that was never in it. Whatever feeds the invocation wins;
# the scan of the whole command stays as the fallback it always was.
def feeding_the_comment(cmd):
    m = re.search(r"basecamp\s+comments\s+(?:create|update)\b[^\n;&|]*", cmd)
    if m is None:
        return None
    invocation = m.group(0)

    delimiter = re.search(r"<<-?\s*['\"]?(\w+)['\"]?", invocation)
    if delimiter:
        body = re.search(r"<<-?\s*['\"]?" + re.escape(delimiter.group(1)) + r"['\"]?\n(.*?)\n"
                         + re.escape(delimiter.group(1)), cmd, re.S)
        return [ body.group(1) ] if body else None

    redirect = re.search(r"<\s*([^\s;|)<>]+)", invocation)
    if redirect:
        expanded = os.path.expanduser(redirect.group(1))
        if os.path.isfile(expanded):
            try:
                return [ open(expanded).read() ]
            except OSError:
                return None
    return None


def heredoc_or_file_body(cmd):
    """Bodies that do not arrive as printf arguments.

    The guard read only `printf '%s\\n' ... | basecamp comments create`. A body
    written by heredoc and posted with `< file` or `-` extracted nothing, so
    `main` exited 0 and the comment went unchecked: six comments posted that way
    in one session were never seen by this hook (defects 2026-08-19). PreToolUse
    runs before the command does, so a file the same command is about to write
    does not exist yet — but its heredoc text is right there in the command.
    """
    blocks = feeding_the_comment(cmd)
    if blocks is None:
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
    prose = [p for p in paras if not NONPROSE.search(MENTION.sub(" ", p))]
    extras = len(paras) - len(prose)
    if len(prose) != 3:
        problems.append(f"{len(prose)} prose paragraphs; the contract requires exactly 3 "
                        "(two of explanation, one of next steps). Tables and images "
                        f"are additional and do not count — {extras} found. A "
                        "bullet list is not additional; it is prose that skipped "
                        "the caps, and it counts.")
    if LISTS.search(text):
        problems.append(
            "bullet list. Lists are exempt from the word and sentence caps, so a "
            "list is where a comment goes to say more than three paragraphs allow. "
            "Say it in the prose or leave it on the bot card. Tables and images "
            "still stand.")

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
            problems.append(f"effort accounting - {why} ({m_.group(0)!r}). What a "
                            "phase cost us and what it touched are both bot-card "
                            "material. If the number changes his decision, give him "
                            "the decision, not the arithmetic; the consequence in "
                            "the same paragraph is what he can act on, and it keeps "
                            "its place once the count around it goes.")

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

    for kind, reference in unlinked_references(text):
        problems.append(
            f"{kind} named without a link ({reference!r}). He has to go and find "
            "it. Link it, with the id as the anchor text - `repo#N` over the pull "
            "URL, the short id over the Sentry issue URL - not the bare URL.")

    for kind, label, target in mismatched_links(text):
        problems.append(
            f"link says {label!r} but points at {kind} {target!r}. One of the two "
            "is wrong and reading will not catch which. Check the id you meant "
            "and make the anchor text and the href name the same thing.")

    for key in unresolvable_links(text, card):
        problems.append(
            f"linked pull request does not exist ({key}). GitHub answered 404. "
            "Check the number before he follows it.")

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
    for pat in ORNAMENT:
        m_ = re.search(pat, text, re.I)
        if m_:
            problems.append(
                f"ornament ({m_.group(0).strip()!r}) - the word is doing the work "
                "the fact should do. It tells him the thing matters without "
                "telling him what breaks, what it costs or what it touches. "
                "Say that, and the word stops being needed.")

    # Prose only. A table cell is a noun phrase by design and a caption names
    # nothing; counting either as an empty sentence would deny the tables he
    # asked for.
    for sent in empty_sentences(prose):
        problems.append(
            f"empty sentence ({sent!r}) - its subject stands in for the thing "
            "instead of naming it, and it carries no number, identifier, path or "
            "proper noun, so its only job is to announce the sentence after it. "
            "Put the fact in this sentence, or delete it and let the next one "
            "stand on its own.")

    for preamble, finding in method_preambles(prose):
        problems.append(
            f"method preamble ({preamble!r}) - it narrates the looking, and he "
            "did not ask how the number was got. The finding carries itself: "
            f"start the sentence at {finding.split()[0]!r}. How it was measured "
            "is bot-card material.")

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
             "do not score it. No ornament: a word that says the thing matters is "
             "standing where the fact belongs. No method preamble - the finding stands "
             "without the clause narrating how it was measured. Every sentence "
             "names what it is about - a placeholder subject with nothing named "
             "only announces the sentence after it. "
             "Every sentence carries a fact the previous one did not; "
             "no paragraph restates itself. No metaphors, and anything counted is "
             "also named. No effort accounting - minutes, estimate error, finding counts "
             "and the count of what the work touched (files, tests, commits) all "
             "belong on the bot card, unless the comment is a postmortem. "
             "Stripped-down directive register - no CTA, no soft ask, no filler. "
             "Tables and images are welcome as extra explanation and are exempt from "
             "the caps; bullet lists are not, because a list is how a comment says "
             "more than three paragraphs allow. The three prose paragraphs stand. "
             "Every factual claim carries a clickable GitHub or Basecamp link.",
             card=card)
    sys.exit(0)


if __name__ == "__main__":
    main()
