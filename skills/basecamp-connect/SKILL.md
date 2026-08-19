---
name: basecamp-connect
description: |
  Manage local Claude Code agents from Basecamp. Runs the connector bridge
  (bin/connect), watches its STDOUT for trusted events — authored by the operator
  and @mentioning a real Basecamp agent user — and hands each off to a background
  agent that gathers context and does the work. Replies are written by the front thread so they carry the
  session's output style, and only when the item's subscribers are just the
  operator and the bot; otherwise the result comes back in the session. In
  Fernando: PSP a two-table routing applies instead: comments on the standing
  intake card start a psp-intake-bug diagnosis on the verbose Bot Card Table, and
  a short human-readable sister card carries the summary.
  Invoked without arguments it recalls the last-used agent and projects from
  ~/.config/basecamp-connect/last.json, confirming them before starting.
  Use when asked to drive local agents from Basecamp, or to watch Basecamp for
  agent commands.
triggers:
  - /basecamp-connect
  - manage agents from basecamp
  - watch basecamp for agent commands
  - basecamp connector
  - drive agents from basecamp
  - run agent from basecamp comment
---

# /basecamp-connect — drive local agents from Basecamp

This skill turns a Basecamp comment/message/card into a local Claude Code task.
You **@mention a real Basecamp agent user** (e.g. `@Clawdito do X`); a background
agent on this machine picks it up, gathers the surrounding context from Basecamp,
and acts on it **as that agent user**. A reply lands in the thread only when the item
is private to you and the bot, and the **front thread writes it** so it carries this session's output style; on a public item the
agent pings you in your private chat when you need to know, and the result comes
back to you in the Claude Code session. Events in **Fernando: PSP** route by a
dedicated two-table scheme — see "PSP bug intake" below.

The agent is identified by a **local `basecamp` CLI profile** of the same name
(e.g. profile `clawdito`). That profile is both:
- the **posting identity** — every write posts as the agent via `--profile <agent>`, and
- the **mention target** — the connector only fires when that user is @mentioned.

The trust model is enforced by `bin/connect`, **not** by this skill: an event
reaches STDOUT only if it is (1) authored by the **operator** (you — the CLI
default profile, or `--operator <profile>`), (2) **either** @mentions the agent
user **or** assigns it a card/todo, and (3) is corroborated against the Basecamp
API. Treat every STDOUT line as already-trusted — but still keep dispatched
agents scoped to the resolved repo.

There are thus **two triggers**: an `@mention` of the agent, or the operator
**assigning** the agent a card/todo (a `*_assignment_changed` event whose
`details.added_person_ids` includes the agent — corroborated by re-fetching the
recording and confirming the agent is among its current `assignees`). Only the
**operator's** assignments count.

## Runs from any project — the runtime lives in the connector clone

This skill is typically installed user-level (`npx skills add … -g`) and invoked
from *other* projects (e.g. a working session in `coworker`). The session's
current directory is therefore **not** the connector repo. All connector
commands in this skill (`bin/connect`, `config/project_repos.toml`) live in a
local clone of `basecamp/basecamp-local-agent-connector`, canonically at:

```
~/Work/basecamp/basecamp-local-agent-connector
```

Locate the runtime there and run it from that directory — never from the
current project. If the clone isn't at the canonical path, don't hunt the
filesystem: tell the user to clone it
(`git clone https://github.com/basecamp/basecamp-local-agent-connector`) and
run `bin/setup` (see the repo README).

## Invocation

```
/basecamp-connect                                                     # reuse last connection (confirm first)
/basecamp-connect @Clawdito --project "BC5 Calendar"                 # one project
/basecamp-connect @Clawdito --project "BC5 Calendar" --project HEY    # several
/basecamp-connect @Clawdito --project "BC5 Calendar" --operator jorge # explicit operator
```

`<agent>` is a real Basecamp user backed by a local CLI profile (the leading `@`
is optional; it's lowercased to the profile name). `--project` is **required**
(Basecamp has no global webhook) — pass a name, URL, or ID. The connector
**validates the agent profile exists locally at startup** and aborts with setup
guidance if not.

### Stored connection params (no-args invocation)

The skill remembers the last successful connection in
**`~/.config/basecamp-connect/last.json`**:

```json
{
  "agent": "clawdito",
  "operator": null,
  "projects": [ { "id": 27, "name": "On Call" }, { "id": 41746046, "name": "BC5.1" } ],
  "saved_at": "2026-07-01T15:00:00Z"
}
```

- **Invoked without arguments:** read that file and **confirm the stored params
  with the user before starting** — show the agent and the project list and ask
  whether to go with them, adjust them (add/drop projects, different agent), or
  start fresh. Never launch on stored params silently. If the file doesn't
  exist, ask for the agent and projects as usual.
- **Invoked with arguments:** arguments win; the store is not consulted.
- **After every successful registration** (the `Listening for mentions of …`
  line), write the params that were actually used back to the file — agent
  profile, operator override (or null), and the projects with their resolved
  ids and names — so the store always reflects the last working connection.
  Create the directory if needed. Launch failures must not overwrite it.

Project ids are stored (not just names) because name lookup is exact-match;
launching from the store passes ids.

## Prerequisite: the agent must be a local profile authed as that user

Before running, confirm the agent name maps to a usable local `basecamp` profile
that is authed **as the agent user** (not as you):

```bash
basecamp me --profile clawdito   # should show the agent's identity, distinct from yours
```

If it's missing or authed as the wrong user, set it up (interactive login as the
agent/bot account):

```bash
basecamp auth login --profile clawdito
```

If the agent profile resolves to the **same** user as the operator, replies would
re-trigger the connector — `bin/connect` warns about this at startup. Use a
distinct bot account for the agent.

## Procedure

### 1. Launch the bridge, then watch its STDOUT

`bin/connect` is a long-running process that never exits on its own — it streams
one trusted event per STDOUT line for as long as it runs. A plain background
task only notifies you when a command *completes*, so on its own it would never
wake you per event. You therefore need **two** steps: run the connector in the
background, then arm a persistent monitor on its output so each new event
notifies you automatically — with no user prompting in between.

**a. Run the connector in the background** and note the output-file path the
harness reports (you need it for the monitor):

```bash
cd ~/Work/basecamp/basecamp-local-agent-connector && \
  bin/connect @Clawdito --project "<project>" [--project "<project>"]...
```

Read that output file once and confirm it printed `Listening for mentions of ...`
(registration succeeded). If it errored instead (unknown agent profile, auth,
project not found), surface that and stop. On success, **save the connection
params** to `~/.config/basecamp-connect/last.json` (see "Stored connection
params" above) so the next no-args invocation can offer them back.

**b. Arm a persistent monitor on that output file** with the Monitor tool
(`persistent: true`). Use `-n 0` so it reports only events that arrive *after*
this point, and filter to the NDJSON event lines so diagnostics stay out of the
stream:

```bash
tail -f -n 0 <connector-output-file> | grep --line-buffered -E '^\{'
```

Each notification the monitor delivers is one event — process it via step 2. An
event that lands while you are waiting on the user is **not** the user's reply.

Each STDOUT line is one trusted event as NDJSON:

```json
{"event_id":99001,"kind":"comment_created","created_at":"...",
 "creator":{"id":100,"name":"Jorge Manrubia","email_address":"jorge@..."},
 "recording":{"id":456,"type":"Comment","app_url":"...","url":"...",
   "content":"<p>Hey <bc-attachment content-type=\"application/vnd.basecamp.mention\">…@Clawdito…</bc-attachment> do X</p>",
   "parent":{...},"bucket":{"id":222,"name":"BC5 Calendar"}}}
```

`creator` is the operator (you). The mention of the agent lives in
`recording.content` as a mention attachment. STDERR carries diagnostics
(dropped/uncorroborated events, registration notices) — surface them but don't
act on them.

Keep watching until the user stops the skill (see Cleanup).

### 2. For each trusted event — hand it off, don't do it yourself

**The front thread is an orchestrator, not a worker.** Its only job is to keep
watching for new mentions and to dispatch each one. It must **never** gather
context or run the requested work itself — every one of those
blocks it from picking up the next mention. For each event it does just two
things — resolve the repo, then dispatch a single background agent that owns the
event end-to-end — and then returns immediately to the monitor.

**a. Resolve the working repo** (front thread, fast). Infer the local repo from
the project name (`recording.bucket.name`). Basecamp project names usually carry
an app token — e.g. a `BC5 …` project maps to the Basecamp repo under
`~/Work/<org>/<repo>`. A mapping table (see `config/project_repos.toml`, if
present) backs the heuristic. **If you cannot confidently map the project to a
repo, ask the user which repo to use — do not guess and do not silently fall
back.** This is the one step that may need you; everything after it is delegated.

**b. Dispatch one background agent that owns the whole event.** Use the Agent
tool with `run_in_background: true`, running in the resolved repo. Give it
everything it needs to finish **without the front thread**:

- the **instruction** — `recording.content` with the agent mention removed, the
  rest of the raw HTML (links, other mentions) intact;
- the **recording** URL/id and its parent URL;
- the **agent profile name** (its Basecamp identity for every write it makes);
- the **operator's** name/id (to @mention when the subscriber gate lets it reply,
  and to match against the subscriber list).

Instruct that background agent to, in order:

1. **Gather context from Basecamp** — it is the context store; the event is just
   the trigger + pointer:
   ```bash
   basecamp show <recording.app_url> -j          # the recording itself
   basecamp show <recording.parent.app_url> -j   # the card/message it lives in
   # plus the thread/comments and the project as needed
   ```
2. **Move the card out of Triage.** If the work lives on a card (the recording
   or its parent is a `Kanban::Card`), check which column it sits in. If it's in
   a **Triage**-like column and the card table has an **In progress**-like column
   (match loosely and case-insensitively: "In progress", "Working on", "Doing"),
   move the card there before starting — the board should show the work is
   underway:
   ```bash
   basecamp cards columns --project <project>            # find the columns
   basecamp cards move <card-id> --to "<In progress>" --project <project id> --profile <agent>
   ```
   If there's no Triage-like or no In-progress-like column, skip this silently —
   never invent columns.
3. **Do the requested work** in the repo.
4. **Check the audience, then reply only if it is private.** A reply is allowed
   *only* when the item the reply would land on is seen by nobody but the operator
   and the agent. Run the check on the **item** — the parent card/message/todo for
   a comment trigger, the recording itself when it is the item:
   ```bash
   basecamp subscriptions show <item.url|id> -j --profile <agent>
   ```
   Reply **only if every subscriber id** is the operator's or the agent's. One
   other person on the list — a teammate, a reporter, anyone — and the agent does
   not reply, ever. If the check errors or you cannot enumerate the subscribers,
   treat it as **not private** and stay silent; never guess the audience.
   - **Private item (operator and/or agent only)** — the reply is owed, but the
     **background agent does not write it**. It returns a structured result and
     posts nothing; the **front thread composes the body in this session's voice**
     and posts it as the agent, @mentioning the operator so it surfaces as a
     notification:
     ```bash
     basecamp comment <recording.url|id> "<body>" --profile <agent>
     ```
     A subagent runs its own context and its own voice; routing the words through
     the front thread is what applies the session's output style. Success posts the
     results; failure posts a short error summary. **Never put the agent's own
     mention in a reply body.**
   - **Anyone else subscribed** — say nothing in the thread at all. Nothing visible
     happens on that item. When the agent needs the operator's
     attention on such an item — it finished something he should see, it is
     blocked, it failed, or it has a question — it pings him in the **operator's
     private chat** instead (see "Escalation channel" below): an @mention, **one
     sentence saying why it needs him**, and the item's `app_url`. Routine "done,
     here it is" on a public item needs no ping — that goes in the session report.
   - **Either way, return the result to the front thread**, which reports it to the
     operator in the Claude Code session: what was done, links to anything it
     produced (PR, card, doc), or what broke and where it stopped. On a public item
     that session report is the *only* place the result appears.
   - Writes the *task itself* asks for (create a card, post a doc, move a column)
     are always fair game — this gate covers answering in the thread, nothing else.

Because the background agent gathers its own context and reports back to the
session, the front thread is free the instant it dispatches — it goes straight back to the
monitor, ready for the next mention while any number of events are in flight.
There is **no concurrency cap**; dispatch every event as it arrives. Composing a
reply at the end of an event is the one piece of work the front thread keeps; it is
words, not context-gathering, and it does not block the next dispatch.

**Escalation channel.** When the subscriber gate blocks a reply but the operator
needs to know something, the agent posts in his private chat in the
**"Fernando: PSP"** project — Campfire room `10157062379`
(<https://app.basecamp.com/2914079/buckets/48348194/chats/10157062379>):

```bash
basecamp chat post "@Fernando.Olivares <one sentence: why this needs you> <item app_url>" \
  --project 48348194 --room 10157062379 --profile <agent>
```

**Every ping leads with one sentence saying why it needs him** — the specific thing
he has to decide, unblock, or look at — then the item's `app_url`. Nothing else:
no recap of the task, no status narration, no restating what the card already says.
Write it so he can tell from that one sentence whether to open the link now or
later. Examples:

- `@Fernando.Olivares The repro procedure for the respond-in-Basecamp bug needs your approval before I can diagnose it. <url>`
- `@Fernando.Olivares I can't reproduce this on iOS 26.1 and need to know which build you saw it on. <url>`
- `@Fernando.Olivares CI is red on the PR for this card and the failure looks unrelated to my change. <url>`

`chat post` resolves `@First.Last` mentions automatically, so the ping arrives as a
real notification. The detail belongs in the session report, not the chat. This
chat is also the right place for a question the agent cannot answer on a public
card. The same one-sentence-why rule applies whenever the agent @mentions him in a
reply on a private item.

**c. Drop self-authored events.** If an event's recording is a comment the agent
itself just posted, ignore it. Posting as the agent (a distinct user from the
operator) already keeps replies from re-triggering the connector — the trust
filter requires the *operator* to be the author — but this is cheap defense in
depth.

### When the agent is assigned a card/todo

If the event `kind` ends in `_assignment_changed`, the operator assigned the
agent to the recording (a card/todo/step) — there's no mention to strip; **the
recording itself is the task**. The dispatched background agent should, in order:

1. **Move the card out of Triage** — same rule as for mentions: if the assigned
   card sits in a Triage-like column and the table has an In-progress-like
   column, move it there before starting; skip silently otherwise.
2. **Do the work** the card/todo describes (its `content`/`title` is the
   instruction; gather context and resolve the repo as usual; if it's a PR task,
   follow the green-first lifecycle below).
3. **Apply the same subscriber gate before replying** — `basecamp subscriptions
   show <recording.url|id> -j --profile <agent>`. Every subscriber the operator or
   the agent: the agent returns its result and the **front thread** writes and posts
   the reply as the agent, @mentioning the operator.
   Anyone else on the list (or a check you cannot complete): no reply — ping the
   operator in his private chat (see "Escalation channel") if he needs to see it.
   Either way, return the result to the front thread for the session report.

The instruction here is the **card/todo content**, not a comment body. Everything
else (resolve repo, one background agent owns it end-to-end, front thread returns
to the monitor) is the same as above.

### PSP bug intake — the two-table routing in Fernando: PSP

Events in **Fernando: PSP (48348194)** route by which card they land on, not by
their content. The project holds two card tables with identical columns (Triage,
Not now, Plan, Design, Code, Review, Test, QA, Postmortem, Done):

| Table | Id | Purpose |
|---|---|---|
| **Human Card Table** | `10216651629` (Plan `10216651634`, Triage `10216651631`) | Fernando's interaction surface. Short, plain, human-readable. |
| **Bot Card Table** | `10157062382` (Plan `10157062387`) | The agent's context store. As verbose as the work needs. |

**The standing intake card is `10216674310`** ("On Call Work Card"), permanently in
Human Triage. It never moves; its comment thread is the work history.

Route on the card the triggering comment sits on:

- **Comment on the standing card `10216674310`** — a **new intake**. It carries a
  source card URL. Dispatch `psp-intake-bug` with the comment and that URL. The
  agent resolves the repo from the source card, splits the report into one bug per
  distinguishable wrong-vs-right result, and for each creates a Bot-table card in
  Plan carrying the simplified plan and a code-backed theory. **When `psp-intake-bug` returns, dispatch `psp-bug-intake-plan-review` before
  writing anything to the Human table.** It sweeps every open question, blocker and
  `UNVERIFIED` claim against the reported-facts ledger and the source card, kills the
  ones the report already answers, and checks the intent verdict, the citations, the
  split and the sizing. Its report is what the human summary is written from — an
  open item it killed never reaches Fernando (defects row 3777). **Intake decides
  whether the behavior was designed** — from a test asserting it, the commit that
  introduced it, an owning PSP effort's acceptance ledger, or the shipped contract —
  and returns `defect`, `working-as-designed` or `never-designed`. Only `defect`
  opens an effort; the other two are scope changes that belong to /psp-plan, and
  intake halts and says so (defects row 3760).
- **Comment on a sister card** — a **response about that one bug**, Fernando's
  approval included. The card identity says which bug; never parse it out of the
  body. When that comment approves the theory and asks for design ("sounds good,
  let's run psp-intake-design"), dispatch `psp-intake-design` with the sister card
  and its bot card. It runs all nine steps of `psp-design` at fix scale, finalizes
  the Approach into the bot card's description, moves **both** cards to Design, and
  halts.
- **Comment on a sister card approving the Approach** — dispatch `psp-intake-code` with the same
  two cards. It absorbs `psp-code` and `psp-test` at fix scale and **runs unattended**: his
  approval is the go for the whole effort, not for its first part, so it never asks permission to
  open one (his ruling 2026-08-19). It opens the PR with an **empty description and leaves it
  empty** — **Fernando writes the description and merges, always.** Its terminal state is a green,
  reviewed PR handed back with the implementation-only diff range, the fix-round count, and the
  manual scenarios queued as unticked `Verify` steps on the bot card; this session posts that
  handoff on the human card, @mentioning him, under the usual contract.

**Both cards are created by the agent the moment a symptom clears dedupe** — the
bot card and its sister, back to back, before any diagnosis. Their appearing is how
Fernando sees that work started. The sister is created with a **plain-language
title and the source card URL as its body**; that title is the only prose the agent
may write in the Human table. Both cards carry the source URL — it is the only
route back to the original report from the card Fernando is looking at.

**The summary is the front thread's.** When an agent returns, this session writes a
short summary in Fernando's voice, @mentions him, and posts it as a comment on the
sister card that already exists. **It always names the proposed direction** — what
the fix would look like, **its size as new-and-changed LOC**, and roughly how far
away it is — and any decision that is his to make. LOC is the measurement the
postmortem computes estimate error against; a summary without it leaves the effort
outside size calibration (defects row 3740). A summary carrying only the mechanism cannot serve a decision, and the
Human table is the decision surface (defects row 3738).

**A design summary carries at most two decisions.** `psp-intake-design` ranks the
open decisions by consequence and brings the top two; every other one stays on the
bot card, and the summary says how many are waiting there. Never imply the list is
empty, and never let the ceiling turn into the agent quietly deciding a third.

**A list of risks is work, not a decision.** The intake path inherits phases from the
full loop that were written as working sessions with Fernando — psp-plan's risk walk,
one risk at a time, is the example — and that shape does not survive onto this surface.
The agent resolves each risk itself: retired, shrunk to a named residual, or accepted
with its reason, all written to the bot card. **Only a risk whose resolution he alone
can make reaches the human card**, and it counts against the two-decision ceiling like
anything else. A risk that already carries a recommendation is resolved, not open: bring
it to him only if choosing against that recommendation is genuinely his call (his ruling
2026-08-19, on a summary that handed back all eight risks as its next step and then spent
its remaining words explaining the first — defects row 3883).

**Bound the claims, not the prose — and prove every one.** The failure mode on this
surface is a summary that asserts a lot and proves nothing, which is both longer and
less useful than one that asserts little and proves it. So:

- **At most three or four factual claims.** If it needs more, the extra ones belong
  on the bot card.
- **Every claim carries its proof inline, as a link he can click.** A bare
  `path/file.rb:41` or a bare short sha is checkable only by someone at a terminal
  with that repo cloned and the right ref checked out, which defeats the point of
  putting proof on the surface he reads (defects row 3776). Use GitHub, pinned at the
  ref the claim was read at:
  - code — `https://github.com/<org>/<repo>/blob/<sha>/<path>#L<line>`
  - commit — `https://github.com/<org>/<repo>/commit/<sha>`
  - PR — `https://github.com/<org>/<repo>/pull/<n>`
  - Basecamp — the recording's `app_url`

  Roster remotes: `bc3`, `bc3-ios`, `hey-ios`, `bc3-desktop`, `hey-electron` are all
  under `basecamp/`. Read the remote with `git -C <repo> remote get-url origin`
  rather than assuming. A claim with no reachable reference is an opinion, and on
  this surface it reads as one.

  Bare `file:line @ ref` stays correct on the **bot** card, which is read beside a
  checkout. This rule is the human table's.
- **Exactly three paragraphs: two of explanation, one of next steps.** A hard
  count, not a target — countable at a glance and impossible to approach gradually.
  Connected prose inside them: no bullet lists, no labelled slots, no telegram.
- **Stripped-down directive register**, the same one the operator's global
  `CLAUDE.md` mandates for every surface. No emoji, no filler, no hype, no
  conversational transitions, no concessions carrying affect ("fair challenge",
  "good question"). Address the reader directly and state things.
- **No CTA. Ever.** The third paragraph names next steps and stops. Never solicit a
  reply, never offer to do something conditional on permission — "say the word",
  "let me know", "want me to" and their family are banned outright (defects rows
  3805, 3806). If you would do the thing on request, either do it or state it as an
  available next step; do not ask for the cue.
- **If it will not fit in two paragraphs, you have too many claims.** Cut claims and
  move them to the bot card; never cut the connective tissue to make room.
- **Never an inventory of unknowns.** Intake's bar is that the card arrives with
  none open (`psp-intake-bug` step 7b): each is settled, or carried as an evaluated
  hypothesis with its consequence. What reaches the sister card is the hypothesis
  and what it means, never the list. "Six unknowns remain" is the phase reporting
  that it did not finish.
- **No internal vocabulary.** Numbered items, "verdict", "retired", "conditional",
  "designed intent", "acceptance rows", "step 2 of the chain", "rival" — none of it
  parses without the bot card open, and a sentence the reader must decode is worse
  than one that is merely long (defects row 3809). Say the thing in his terms: not
  "item 1 is retired by ruling", but what we are now assuming and what breaks if the
  assumption is wrong.
- **No bookkeeping. The card is a decision surface, not a ledger of our process.**
  Never report where something was filed, cite a defect row number, name a ledger
  file, or narrate that a card now carries a comment. None of it changes a decision
  he makes, and every such sentence displaces the finding it precedes (defects row
  3808). A link to fuller detail is not bookkeeping and stays; a sentence announcing
  that we wrote something down is. State the finding, not its filing.
- **The last sentence names the next step.** Always, and as the final thing in the
  second paragraph — what happens next, who owns it, and what it unblocks. Name the
  disposition outright: ready for design, blocked on a check only Fernando can run,
  blocked on the reporter, going to planning as a scope change, or closed. A summary
  can satisfy every other requirement and still leave the reader guessing whether
  anything is waiting on them, which is the one thing a decision surface exists to
  deliver (defects row 3804). "Here is a cheap experiment" is not a disposition —
  say whether the effort proceeds without it.

Four failures bracket this contract, all on the same surface: a 350-word wall he had
to read twice (row 3758), a slot template that produced seven disconnected one-liners
(row 3759), a 300-word summary making six unreferenced assertions (row 3774), and a
four-paragraph answer written with the contract loaded (row 3803). Short, cohesive,
and proven are three separate requirements, and optimising for any one alone has now
failed three times.

**The ceiling is a count, not a range, because ranges do not hold.** Every earlier
version of this rule gave a word range, and every one was exceeded by the writer who
had it in context — a range has no failure condition you can check yourself against,
so it reads as permission to reach its top. Three paragraphs either is or is not.

**And it is enforced, not merely written down.** A `PreToolUse` hook
(`~/.claude/hooks/psp-human-card-guard.py`, wired in `~/.claude/settings.json`)
intercepts every `basecamp comments create|update` whose target resolves into the
Human Card Table and denies the call on: a paragraph count other than three, more
than **150 words total**, more than **60 words** or **4 sentences** in any
paragraph, any single sentence over **40 words**, any banned soft-ask/CTA/filler
phrase, any emoji, or a final paragraph with no stated next step. URLs do not count
toward the word budget — they are proof, not prose.

**Every dimension is capped because capping one displaces the growth into another.**
Bounding words produced a slot template; bounding paragraphs grew the paragraphs
(213 to 281 words with the count unchanged); bounding sentences alone would produce
run-on sentences. The caps are simultaneous for that reason, and the denial names
the actual counts so the fix is arithmetic rather than judgement. Six written amendments to this contract were each violated by the writer
who had them loaded; the seventh is a gate. Adding a rule here without adding its
check leaves the same gap.

**Every requirement added here replaces something; it never appends.** The summary
reached 350 words by gaining one mandatory element per defect fixed — direction,
size, ranked decisions, the count — with nothing bounding the total. If a new element
genuinely must appear, say which one it displaces. That @mention is the only
notification he gets — the Campfire escalation channel does not apply in this
project, because the sister card replaces it.

The sister mirrors its bot card on **every** column transition from creation
onward. During intake both simply sit in Plan.

**An intake that ends without a build gets a postmortem, and the card waits for it.**
When an effort closes with no code written — Not now, retired as a scope change, superseded,
duplicate — dispatch `psp-intake-postmortem` **before** the human card moves to its terminal
column. The unit is the human card, and the move is what publishes the closure, so the move is
held until the report posts (Fernando's ruling 2026-08-19).

It measures what a diagnosis-only effort has and refuses what it does not: minutes to verdict,
how many times the verdict changed and what changed it, which filter caught each defect and which
reached Fernando, and — the reason it exists — the earliest point the closing evidence was
reachable, which yields a wasted-rounds figure. No LOC, no estimate error, no defects/KLOC: there
is no build to divide by, and a fabricated zero enters the cross-effort trend as real. Its report
lands on the bot card and its measures on the `projects.jsonl` row, and **this session then posts a
short summary of it on the human card, @mentioning him** (his ruling 2026-08-19) — same contract,
same hook, same three paragraphs as every other Human-table comment. The summary leads with the
wasted-rounds figure and what closed the effort, names the true cost where it differs from the
minutes booked, carries the lesson line, and states the disposition. A close-out he never sees
measures nothing he can act on.

This exists because one source card produced five effort rows, 381 minutes and 119 defect rows
tonight, and every one of those rows was terminal with `actual: null` — invisible to calibration,
since `psp-postmortem` measures a build and none of them built anything.

**Division of labor, absolute:**

- The **agent** owns the Bot table outright — cards, comments, moves — plus the
  Human table's structural actions: creating sister cards with their titles, and
  column moves. **The bot never boosts anything, anywhere.** Every action ends in a
  card or a comment, so a boost is only a second, weaker acknowledgement of something
  already visible.
- **This session** owns every Human-table **comment**. The agent never comments
  there.
- The **source card is never touched** — no comment, no move, no edit. It
  usually lives on a shared team board, where a PSP gate notifies people about our
  internal process instead of about their bug.
- **A write is not done because the CLI said `ok`.** `basecamp cards update` has
  reported success while silently dropping a 14KB body, and `basecamp comments update`
  has reported success against a comment id that does not exist — an id one digit off a
  real comment would have overwritten it (defects rows 3775, 3826). Ids for in-place
  updates come from a `comments list` in the same round, and every write is confirmed by
  re-reading the target, not by the exit status.

The subscriber gate is not consulted here. Fernando: PSP has exactly two members,
so every card in it is private by construction; the routing above, not the gate, is
what decides where words go.

### The front thread is a thin orchestrator

It routes events, it writes the human-facing prose, and it does nothing else. It does
not investigate, does not gather context, and does not carry findings from one agent
into another's prompt. Every event reaches it first — the monitor wakes nothing else —
and its only decision is which of three routes the event takes.

**Answer directly** when the answer is already in this session: what an agent
reported, what was decided, what a card says. Post the reply on the sister card in
Fernando's voice. Reporting only in session is not answering — that mistake left a
card standing with a recommendation the evidence had already killed.

**Resume the owning agent** — `SendMessage` to its id — whenever the question turns on
evidence that agent gathered. It still holds its own investigation and can re-derive
from it; the front thread cannot. This is the default for follow-ups, corrections and
challenges to a finding. Prefer it over a fresh spawn every time it applies. Its
context dies with the session, so resume while you still can.

**Spawn fresh only for new investigation** — work no existing agent has done.

### Claims are reviewed before they reach the Human table

**Anything that makes or revises a factual claim goes through
`psp-bug-intake-plan-review` before it reaches Fernando's card.** Not only the
initial intake run — a resumed agent answering a follow-up produces claims too, and
a follow-up answer is where an agent is most likely to restate a conclusion more
confidently than its evidence supports.

The line is claims, not agents and not phases:

- **Reviewed** — new evidence, a changed conclusion, a re-assertion of *how*
  something is known, a size or estimate, a verdict.
- **Not reviewed** — pure retrieval: a card id, a column, a restatement of what a
  comment already says, a link.

**Scope a follow-up review to the new or changed claims only.** The facts ledger,
the citations and the split were verified on the first pass and are not re-derived;
the first full pass on an effort ran ten minutes and 130k tokens, and repeating it
per question would make the check cost more than the answer. The reviewer is told
what changed and checks that.

Two things tonight are why this is a rule. The reviewer's first pass returned three
blocking findings on work that read as sound, including a time row whose stated
measurement was impossible against its own timestamps. And the intake agent,
re-checking its own work, mis-invoked `git` in a way that would have reversed its
conclusion had it not caught itself — a self-check is not a check.

### A fresh agent's context is the card, not this session

**Dispatch prompts carry pointers, never findings.** Give a fresh agent the card ids,
the source card URL, its Basecamp identity, the task and the constraints. Do **not**
summarize what earlier agents concluded, what the theory is, or what the evidence
showed. It reads all of that off the bot card, which is why the bot card is verbose.

Three reasons this is a rule and not a preference:

- **The front thread's memory is not durable.** This conversation is summarized as it
  grows and is gone when the session ends. The card is what survives, and an agent
  that depends on the session's recollection cannot be re-run tomorrow.
- **A relayed finding is a finding without its evidence.** Passed through a prompt it
  arrives as an assertion the agent is likely to accept, which is how a reviewer's
  doubt came to outrank a correct reading (defects row 3777).
- **It makes the card's completeness testable.** If a fresh agent cannot reconstruct
  the effort from the card and its links, the card is deficient — and that is a defect
  worth finding, not a gap to paper over from session memory.

**When the front thread knows something the card does not, write it to the card** —
Fernando's ruling in chat, a constraint agreed in session, a correction. Putting it
in a prompt hides it from every later reader; putting it on the card makes it context
for all of them.

The narrow exceptions are facts that exist nowhere else and are not findings: the
agent profile name, card and column ids, the repo roster, and explicit prohibitions.

### Repo isolation — dispatched agents never work in a shared checkout

The roster repos are Fernando's live checkouts, shared with him and with every
other agent running concurrently. Two agents dispatched from one source card land
in the same repos at the same time, and a `git checkout` in either moves `HEAD`
under the other (defects row 3757).

Every dispatch carries this rule:

- **Read-only work needs no isolation**, but it must stay read-only. Pinned refs
  are read with `git show <ref>:<path>` and `git -C <repo>`, never by checking the
  ref out. `checkout`, `switch`, `stash`, `clean` and `reset` are banned in a
  shared checkout.
- **Anything that builds, tests, or writes code gets its own worktree**, one per
  repo, under the agent's scratchpad: `git -C <repo> worktree add <path> <ref>`.
  This is the existing rule for PR tasks, generalized — it is not only for PRs.

The Agent tool's `isolation: "worktree"` flag does **not** cover this: it anchors a
worktree to the session's own repo, the connector session's directory is not a git
repository, and a dispatched agent typically spans two or three repos. The worktree
has to be created per repo by the agent itself.

### Validate a finished body of work with `bin/ci` (in the background)

Whenever a coherent body of work is finished — the initial implementation, a
round of changes, a fix, a review-feedback pass — validate it by running the
repo's `bin/ci` **in the background** (non-blocking) before reporting done.
Aggregate as much as possible into a single run: don't re-run after every small
edit, but as a general rule run `bin/ci` once at the **end** of the body of work.
Running it in the background keeps the agent free and surfaces failures without
stalling; fix anything it flags before you report "done."

```bash
bin/ci --force > /tmp/ci-<branch>.log 2>&1; echo "EXIT=$?" >> /tmp/ci-<branch>.log   # background
```

PR tasks are stricter — they follow the green-first lifecycle below, where
`bin/ci` must pass (and remote checks too) *before* the work is reported. This
background-`bin/ci` rule is the baseline for all other work (e.g. a direct change
that's committed and deployed without a PR): still run `bin/ci` at the end.

### When the task results in a pull request

Some instructions are "open a PR for X." For these the background agent follows a
stricter lifecycle and **must not report the work done until the branch is
green** — getting CI green is part of finishing the task, not a follow-up:

1. **Work in a fresh worktree off `main`** — `git worktree add -b <branch> <path>
   main` in the resolved repo, so the task is isolated and `main` stays clean. Do
   all the work there.
2. **Green locally first** — run `bin/ci` in the worktree and iterate until it
   passes. Never push red.
3. **Push and open the PR.**
4. **Green remotely** — `gh pr checks <n> --watch --fail-fast`; if a check fails,
   fix it, push, and re-watch. Loop until every check is green (remote can fail
   what local passed).
5. **Only now report done** — to the front thread with the PR link, and on
   Basecamp too if the subscriber gate passes. Never communicate success on a red
   or unchecked branch. If you cannot get it green after a reasonable effort,
   report **what is failing** and where you stopped — not a false "done."

#### Review / approval loop (GitHub webhook)

Once the PR is up and green, reviews are handled **event-driven via a GitHub
`pull_request_review` webhook**, not by an agent sitting in a poll loop: a human
review is unbounded latency, an idle LLM agent is the wrong tool for it, and an
in-session agent would die when the session ends. **`bin/connect` is unified** —
the same process that watches Basecamp also watches GitHub repos, over the
**same funnel**, when you pass `--repo`:

```bash
bin/connect @Clawdito --project "<project>" --repo <owner>/<repo>
```

It emits GitHub review events on the same STDOUT as Basecamp events (a review
event carries `review_id`/`repo`/`state` instead of `recording`), so the one
persistent monitor you already armed picks them up too. For a repo created
**after** the connector started (the common PR case), don't restart it — the
connector logs a `/gh/<secret>` endpoint + HMAC secret at startup; register a
`pull_request_review` webhook on the new repo against that endpoint (one webhook
per PR's repo, all multiplexed onto the single funnel). Branch on `state`:

- **`changes_requested` / `commented`** — re-fetch the *whole* review (body +
  inline comments) from the API (the webhook is a trigger + pointer, exactly like
  the Basecamp side), address the feedback in the worktree, re-green (steps 2–4),
  and push. GitHub review threads are the exception to the no-reply rule: replying
  on the PR is allowed and expected — the ban covers the Basecamp thread that
  tagged the agent.
- **`approved`** — land per the repo's policy and report done to the front thread.

GitHub webhooks carry an HMAC secret (`X-Hub-Signature-256`), so unlike Basecamp
deliveries they are verified cryptographically *and* corroborated by an API
re-fetch. The connector-side plumbing that backs this loop (the unified
`Connector` + the GitHub `Bridge` route: register the repo hook, verify the
signature, parse `pull_request_review`, emit) is specced in
[`docs/pr-review-loop.md`](../../docs/pr-review-loop.md).

## Cleanup / lifecycle — always tear down

`bin/connect` opens a **public** Tailscale Funnel URL and registers a **real
Basecamp webhook per project**. These must not outlive the session. The
connector deletes every webhook and resets the funnel on `SIGINT`/`SIGTERM`, so
the rule is simple: **whenever you stop watching — normal end, user interrupt, an
error, or the skill aborting — stop the `bin/connect` process** (TaskStop / send
SIGTERM). Its teardown does the rest.

After stopping, **verify nothing leaked**:

```bash
basecamp webhooks list --project "<project>" -j   # expect zero from this run
tailscale funnel status                            # expect no funnel for our port
```

If the process was killed un-gracefully (e.g. `SIGKILL`) and teardown didn't run,
delete the leftover webhook(s) manually with `basecamp webhooks delete <id>
--project "<project>"` and `tailscale funnel reset`. Never leave a registered
webhook or an open funnel behind.

## Notes

- One `bin/connect` run = one funnel + one server + one webhook per watched
  project. Re-running re-registers fresh; exiting cleans up.
- The connector never trusts the POST body's content — it re-fetches the
  recording from Basecamp before emitting. The content you see on STDOUT is the
  authoritative copy.
- **Audience gate on replies:** a reply lands in a thread only when the item's
  subscribers are the operator and/or the agent — a private item. Any other
  subscriber and nothing visible happens on that item; anything the operator must
  see goes to his private chat (room `10157062379`) and to the session report. An un-enumerable subscriber list counts as public. The words are
  always the front thread's, never the background agent's.
- **Fernando: PSP is routed, not gated.** Its two members make every card private
  by construction, so the gate never decides anything there — "PSP bug intake"
  above does, and its sister card replaces the Campfire ping.
- **Campfire cannot be a trigger.** Basecamp refuses every chat type at webhook
  registration (`Chat::Line`, `Chat::Transcript::Line`, `Campfire` and friends all
  return `types: must be eligible`), so a chat mention never reaches the bridge.
  Chat is an outbound channel only. Inbound always arrives as a `Comment`,
  `Message`, `Kanban::Card`, `Kanban::Step` or `Todo`.
- **Reply loop (defense in depth):** trust is "authored by the operator AND
  mentions the agent," so a reply posted as the agent (a distinct user) fails the
  operator-author check and is never re-ingested. Keep the agent's own mention out
  of reply bodies.
