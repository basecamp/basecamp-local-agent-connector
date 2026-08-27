---
name: basecamp-connect
description: |
  Manage local Claude Code agents from Basecamp. Runs the connector bridge
  (bin/connect), watches its STDOUT for trusted events — authored by the operator
  and @mentioning a real Basecamp agent user — and hands each off to a background
  agent that gathers context and does the work. Replies are written by the
  `psp-card-writer` agent, which reads the work's own card and composes for a
  reader, and only when the item's subscribers are just the
  operator and the bot; otherwise the result comes back in the session. In
  Mobile: On Call a two-table routing applies instead: a card on the Issues board
  starts a psp-intake-plan diagnosis on the verbose Bot Card Table beside it, and
  that same board card carries the human-readable summary — started by Fernando
  assigning the bot or @mentioning it, or fired automatically when MobileBot files
  a Sentry crash card or when anyone files a card into Triage.
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
is private to you and the bot, and **`psp-card-writer` writes it** — a dedicated writing agent that reads the work's card and composes for a reader; on a public item the
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

There are thus **three triggers**: an `@mention` of the agent, the operator
**assigning** the agent a card/todo (a `*_assignment_changed` event whose
`details.added_person_ids` includes the agent — corroborated by re-fetching the
recording and confirming the agent is among its current `assignees`), or the
operator **pinging** the agent (a `chat_line_created` event in a `Circle` bucket —
corroborated by re-fetching the line and confirming the conversation's only
participants are the operator and the agent). Only the **operator's** assignments
and pings count.

**Pings only arrive under `bin/poll`, or under `bin/connect` with its ping
thread** — Basecamp registers no webhook for chat of any kind, so nothing
delivers one. Both entry points poll for them by default; `--no-pings` turns that
off.

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
  "watched_columns": [ "<project>:<sentry-column>:<mobilebot>", "<project>:<triage-column>" ],
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
  profile, operator override (or null), the projects with their resolved
  ids and names, and any `--watch-column` specs — so the store always reflects
  the last working connection.
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
  bin/connect @Clawdito --project "<project>" [--project "<project>"]... \
    [--watch-column BUCKET:COLUMN[:CREATOR]]...
```

`--watch-column` is the one trigger that does not need the operator (see "On-call
board intake" below). Its bucket must also be a `--project`, or no delivery ever
arrives to match it; the connector warns when it cannot see one.

**On a network that cannot carry inbound traffic, use `bin/poll` instead.**
`bin/connect` needs Basecamp to reach this machine over a public Tailscale Funnel
URL, and a restricted network breaks that at the DNS layer: on an airplane
connection Tailscale never published the node's `ts.net` record, and every
webhook registration failed with `payload_url: must resolve to an active public
IP` while the funnel reported itself healthy locally. The tell is that error, or
a `ts.net` name that returns NXDOMAIN from a public resolver.

```bash
cd ~/Work/basecamp/basecamp-local-agent-connector && \
  bin/poll @Clawdito --project "<project>" [--project "<project>"]... \
    [--watch-column BUCKET:COLUMN[:CREATOR]]... [--interval 60]
```

It emits the same NDJSON through the same trust pipeline, needs only outbound
HTTPS, and registers nothing — so step 2 and everything after it is unchanged,
and there is nothing to tear down. It confirms itself with `Starting from now`
rather than `Listening for mentions of ...`: a first run marks what is already
waiting as handled instead of replaying it, since the agent's inbox holds every
mention it has ever received. Pass `--backfill` to pick up a backlog on purpose.
The one thing it does not cover is the GitHub PR-review loop, which rides the
funnel; reviews still need `bin/connect`.

Read that output file once and confirm it printed `Listening for mentions of ...`
(or `Starting from now` in poll mode). If it errored instead (unknown agent
profile, auth, project not found), surface that and stop. On success, **save the connection
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

`creator` is the operator (you) — on every path but one. A card creation matched
by `--watch-column` carries whoever filed it, which is the point of that path;
route on the card, not on the assumption that you authored the event. The mention
of the agent lives in `recording.content` as a mention attachment. STDERR carries diagnostics
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
     posts nothing itself; **it dispatches `psp-card-writer` as its last act**,
     which reads the item and the work's own card and posts the reply as the agent,
     @mentioning the operator so it surfaces as a notification:
     ```bash
     basecamp comment <recording.url|id> "<body>" --profile <agent>
     ```
     A working agent runs its own context and its own voice, and prose drafted
     between interrupts by the thread that is also routing events reads like it.
     A separate writer with nothing else to do is what fixes that. Success posts the
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
There is **no concurrency cap**; dispatch every event as it arrives. The reply at the
end of an event is a dispatch too — `psp-card-writer`, with pointers — so nothing the
front thread does is composition, and nothing it does blocks the next event.

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
   the agent: before returning, the agent dispatches **`psp-card-writer`**, which
   writes and posts the reply as the agent, @mentioning the operator.
   Anyone else on the list (or a check you cannot complete): no reply — ping the
   operator in his private chat (see "Escalation channel") if he needs to see it.
   Either way, return the result to the front thread for the session report.

The instruction here is the **card/todo content**, not a comment body. Everything
else (resolve repo, one background agent owns it end-to-end, front thread returns
to the monitor) is the same as above.

### When the operator pings the agent

If the event `kind` is `chat_line_created`, he sent the agent a **ping** — a
Basecamp direct message. There is no mention to strip and no card to move: the
line's content is the whole instruction, and the conversation is the item.

**The conversation is already private.** The connector emitted this only after
confirming from Basecamp that its participants are exactly the operator and the
agent — that check is what stands in for the @mention every other trigger needs.
So the subscriber gate is **already satisfied**: a reply is owed and goes back
into the same ping. Do not re-run `subscriptions show` on a circle; it is not a
card, and the read the connector already made is the authoritative one.

**Everything lives in one conversation.** Basecamp allows exactly one 1-on-1 ping
per person, so every effort's pings interleave in a single thread — there is no
per-effort ping and no way to make one. Two things follow, and both are contract:

- **Every ping the agent sends names its effort and ends with the routing line.**
  Three paragraphs, then `Reply to card <bot card id>` on a line of its own — and
  that last line **only on a ping that asks him something.** A close-out or a
  "the PR is green" ends after the third paragraph, or the token becomes noise
  and he stops copying it back.
- **Every ping he sends is routed by the card id he quotes back.** Scan his line
  for any run of 8+ digits and match it against the bot cards the agent has
  pinged about and is still awaiting an answer on. That is a closed set, so a
  version number or a PR number in his prose cannot collide with it.

**When no id resolves** — he replied "yes" and nothing else, which is the natural
thing to type — fall back: if exactly one effort is awaiting an answer, it is
that one. If more than one is, **ask him in the thread** rather than guessing.
A wrong guess acts on the wrong effort.

**Reading and writing a ping.** A ping answers the Campfire line endpoints on a
`Circle` bucket and nothing else — `basecamp show` cannot fetch one, and neither
can `basecamp url parse`. The two ids come off the event itself:
`recording.bucket.id` is the circle, `recording.parent.id` is the transcript.

```bash
basecamp api get "buckets/<circle>/chats/<transcript>/lines.json" --profile <agent>   # newest first
basecamp api post "buckets/<circle>/chats/<transcript>/lines.json" \
  --data '{"content":"<p>…</p>"}' --profile <agent>
```

**The agent never writes the ping itself.** It dispatches **`psp-card-writer`**
with the destination set to the ping, exactly as it would for a private card —
pointers only, never findings, and everything the writer needs on the bot card
before the launch. The `psp-ping-guard.py` hook holds that write to the same
contract the human-card comment obeys.

**Replies do not re-trigger.** The agent's own lines land in the same
conversation, and the trust filter requires the *operator* to be the author, so
they are read and passed over. Do not try to suppress them any other way.

### PSP bug intake — the two-table routing in Mobile: On Call

Both tables live in **Mobile: On Call** as of 2026-08-24. The human surface is
the team's own Issues board; the Bot Card Table is a shared context store beside
it, carrying the PSP phase columns.

**Every id — both tables, all their columns, the operator, the agent — lives in
`~/.config/psp/board.json` and nowhere else.** Print them with:

```bash
python3 ~/.claude/skills/psp/scripts/psp-board.py --surfaces
```

Nothing below quotes an id, and neither should you or anything you dispatch. That
is not tidiness: when these tables moved projects an agent briefed with a
remembered id created a card and posted twelve comments into a retired board and
read them back clean, because a moved card's old id **resolves on read** while
writes against it return `{"id": null}` inside an ok-shaped envelope. The config
is written once by mobile-alerts `psp/bin/psp-setup` and verified with `psp-board.py --check`.

| Table | Purpose |
|---|---|
| **Human Card Table — Issues** | Fernando's interaction surface, shared with the mobile team. Short, plain, human-readable. |
| **Bot Card Table** | The agents' context store, shared across the team so dedupe sees every prior effort. As verbose as the work needs. |

**There is no standing intake card any more.** It lived in the retired PSP human
table and was a second door into a room the board already opens: every card on
Issues is dispatchable directly, by the three triggers below. Intake starts on the
card that carries the bug, never on a card about starting intake.

**Bot cards before 2026-08-24 lived in Fernando: PSP (48348194, table
`10157062382`).** The twenty-one with a live human card were teleported across and
their `projects.jsonl` rows repointed; the rest stayed as closed history. An old
id **still resolves on read and silently drops writes** — `basecamp comments
create` against one returns `id: null` inside an ok-shaped envelope — so a card id
that did not come out of the current ledger row is a write that vanishes.

Route on the card the triggering event lands on:

- **A card on the Issues board, by one of the three triggers below** — a **new
  intake**. Dispatch `psp-intake-plan` with the card. The agent resolves the repo
  from it, splits the report into one bug per distinguishable wrong-vs-right
  result, and for each creates a Bot-table card in Plan carrying the simplified
  plan and a code-backed theory. **The reviewer pass is
  the agent's, not yours — `psp-intake-plan` §7c launches `psp-intake-plan-reviewer`
  itself, and this route no longer dispatches one.** The instruction used to live
  here, in this route's prose, and it was skipped 10 times out of 10 on the night a
  second route was added that never mentioned it; owning the launch inside the agent
  is what makes the pass route-independent. Read its result for the pass and say so
  if it is missing — do not launch a second one, because exactly once means exactly
  once. It sweeps every open question, blocker and
  `UNVERIFIED` claim against the reported-facts ledger and the source card, kills the
  ones the report already answers, and checks the intent verdict, the citations, the
  split and the sizing. Its report is what the human summary is written from — an
  open item it killed never reaches Fernando (defects row 3777). **Intake decides
  whether the behavior was designed** — from a test asserting it, the commit that
  introduced it, an owning PSP effort's acceptance ledger, or the shipped contract —
  and returns `defect`, `working-as-designed` or `never-designed`. Only `defect`
  opens an effort; the other two are scope changes that belong to /psp-plan, and
  intake halts and says so (defects row 3760).
- **A comment carrying a card URL *and* a pull request URL** — a
  **code review intake**. Somebody else has already worked the card and opened a PR,
  and the question is whether that PR is right. Dispatch `psp-intake-code-review`
  with the comment, the card URL and the PR URL. It runs the same intake as
  `psp-intake-plan` — reported-facts ledger, classification, split, dedupe, its own
  bot card, the plan comments — then **diagnoses the bug blind**, from the code at
  the PR's merge-base with the diff unread, posts that theory, and only then opens
  the patch and maps every hunk to a hop of the mechanism. It returns
  `solves-it` / `solves-with-gaps` / `wrong-mechanism` / `undetermined`, a tiered
  findings list, and a plain-language `Verify` script queued on the sister card.
  **Two rules are specific to this route.** It never touches the pull request —
  no comment, no review, no label, no merge — so anything reaching its author goes
  through Fernando. And it **never adopts a shared board card**: the human surface
  is always a sister in the PSP Human Card Table, because a review of someone
  else's work is private between him and the agent. When the comment carries a PR
  URL but asks for a diagnosis rather than a judgment, that is still
  `psp-intake-plan`; when the ask is genuinely ambiguous, ask him in his chat room
  rather than guessing, because the two agents produce different artifacts and the
  wrong one costs a full run.
- **Comment on a human card** — a **response about that one bug**, Fernando's
  approval included. The card identity says which bug; never parse it out of the
  body. When that comment approves the theory and asks for design ("sounds good,
  let's run psp-intake-design"), dispatch `psp-intake-design` with the human card
  and its bot card. It runs all nine steps of `psp-design` at fix scale, finalizes
  the Approach into the bot card's description, moves **both** cards to Design, and
  halts.
- **Comment on a human card approving the Approach** — dispatch `psp-intake-code` with the same
  two cards. It absorbs `psp-code` and `psp-test` at fix scale and **runs unattended**: his
  approval is the go for the whole effort, not for its first part, so it never asks permission to
  open one (his ruling 2026-08-19). It opens the PR with an **empty description and leaves it
  empty** — **Fernando writes the description and merges, always.** Its terminal state is a green,
  reviewed PR handed back with the implementation-only diff range, the fix-round count, and the
  manual scenarios queued as unticked `Verify` steps on the human card; this session posts that
  handoff there, @mentioning him, under the usual contract.

**The pair is made by the agent the moment a symptom clears dedupe** — the bot card
and its human card, back to back, before any diagnosis. Their appearing is how
Fernando sees that work started. When the trigger was a board card, that card is
the human card and no second one is made; otherwise the agent creates one in Issues
Triage with a **plain-language title and the source card URL as its body**, and
that title is the only prose it may write there. The pairing has to read from both
ends — the bot card carries the human card's URL, the human card carries the
report's — because that is the only route back to the original complaint from the
card Fernando is looking at.

**The summary is `psp-card-writer`'s, and the agent that did the work dispatches it.**
Not this session. Every working agent's last act before returning is to launch the
writer with pointers — the human card, the bot card, the route — and the writer reads
the bot card, writes a short summary in Fernando's voice, @mentions him, and posts it.
**The front thread never drafts it and never dispatches it**, except for a comment no
agent worked for: an answer already in this session.

**The launch lives in the agent because a caller's launch does not happen.** The same
rule was written twice here for `psp-intake-plan-reviewer` and skipped ten times out of
ten on the night a second route was added that never mentioned it, while agents owning
their own launch ran seven of seven. This session routes events and forgets; an agent
finishing is not an inbound event, so the comment it owes is the thing most likely to
be dropped, and it was — repeatedly, until Fernando asked where it was.

**The writer may halt instead of posting**, handing back questions its bot card could
not answer. That is a card defect, and the agent that owns the card answers onto the
card and dispatches it again. **It always names the proposed direction** — what
the fix would look like, **its size as one new-and-changed LOC figure**, and roughly
how far away it is — and any decision that is his to make. **One figure, never an
inventory**: "20 added against 182 deleted plus 32 of workflow" is the arithmetic
under a number, not the number. And **at merge time, none at all** — the code exists,
its size changes nothing he does, and `psp-postmortem` measures the real figure from
git either way (his ruling 2026-08-25). LOC is the measurement the
postmortem computes estimate error against; a summary without it leaves the effort
outside size calibration (defects row 3740). A summary carrying only the mechanism cannot serve a decision, and the
human card is the decision surface (defects row 3738).

**When intake offers a product alternative, the summary carries the choice, not the winner with a
footnote.** Both directions, each with its size and what it gives up, and the recommendation. This
replaces elaboration of the mechanism rather than adding to the budget: with two directions on the
card, the reader needs enough of the mechanism to judge them and no more, and the rest stays on the
bot card. A choice he cannot see is a choice he cannot make — the desktop sign-out effort's cheaper
direction reached him only because it happened to land in a summary's last sentence, and it turned
a 100-line change in one repository into 22 lines in another.

**A code-review route is not complete until its summary lands on the sister card.** The agent
halts with the human card holding its title, its two URLs and its unticked `Verify:` steps and
nothing else — that is its contract, not an oversight — so the verdict exists only on a bot card
until the writer posts. On the first live run it stayed there until Fernando asked where it was.
Treat the summary as the last step of the route rather than as a courtesy after it, and post it
before reporting the run as done.

**A code-review summary leads with the verdict and what accepting the PR costs.** Not the
mechanism, not the findings inventory — `psp-intake-code-review` returns a disposition (merge
as-is, merge with a named follow-up, do not merge) and one sentence that decides it, and that
sentence is the summary's first. Blockers are named; nits are counted, never listed. It also
carries the recommendation the author could act on, because Fernando is the only channel to them
— the agent never posts on the pull request. The `Verify` steps are already queued on the sister
card, so the summary points at them rather than restating them.

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
- **At most three paragraphs: explanation, then one naming the next step.** A
  ceiling, countable at a glance. **Fewer is fine and often right** — a comment with
  two things in it gets two paragraphs, and padding to three is how a short answer
  becomes a long one (his ruling 2026-08-25, on a merge summary he rewrote into two).
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
  none open (`psp-intake-plan` step 7b): each is settled, or carried as an evaluated
  hypothesis with its consequence. What reaches the human card is the hypothesis
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
  disposition outright: ready for design, **ready for code with design skipped and the artifact
  that pins the shape named**, blocked on a check only Fernando can run,
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

**The ceiling is a ceiling, never a target, because targets do not hold.** Every
earlier version of this rule gave a word range, and every one was exceeded by the
writer who had it in context — a range has no failure condition you can check
yourself against, so it reads as permission to reach its top. Three either is or is
not exceeded; nothing about it says to reach it.

**And it is enforced, not merely written down.** A `PreToolUse` hook
(`~/.claude/hooks/psp-human-card-guard.py`, wired in `~/.claude/settings.json`; it lives in mobile-alerts `psp/hooks/` and is linked from there by `psp/bin/install`)
intercepts every `basecamp comments create|update` whose target resolves into the
Human Card Table — the Issues board — and denies the call on more than three prose
paragraphs, a total or per-paragraph or per-sentence length over its caps, a bullet
list, a banned soft-ask/CTA/filler phrase, an emoji, internal vocabulary, effort
accounting, an unlinked claim, or a final paragraph with no stated next step. URLs do
not count toward the word budget — they are proof, not prose.

**The caps themselves are deliberately not written here.** Every prose copy of them has
gone stale: this file said 150 words, 60 per paragraph, 4 sentences and 40 words per
sentence while the hook enforced different numbers, and `psp-intake-code-review` still
handed those dead figures to whoever drafted. The hook is the only true statement of
the contract, and it can be run against a draft **before** any CLI call:

```bash
python3 ~/.claude/hooks/psp-card-preview.py <human-card-id> <draft-file>
```

It drives the guard itself on a synthesized payload rather than re-implementing a
single check, so it cannot drift. `psp-card-writer` loops on it until it prints
`passes`, and nothing reaches the CLI that has not.

**The author is enforced too, not just the prose.** The same hook reads `agent_type`
off the `PreToolUse` payload — absent on a main-thread call, the subagent's name
otherwise — and denies any prose comment on the Human Card Table that did not come
from `psp-card-writer`. The refusal names the handoff rather than just the rule.
Phase lines exit before that check, so every agent still posts its own.

**This is what makes an amendment to this contract binding.** A session that loaded
this skill before an edit never sees the edit — the description propagates, the body
does not. On 2026-08-25 the writing role moved to the writer agent and a live
connector session went on holding the previous body for three hours, having agreed to
a change it could not read. Every earlier amendment here was violated the same way,
and each time the fix was more prose. A rule that binds only sessions started after it
was written binds nothing.

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
project, because the human card replaces it.

The human card follows its bot card on **every** column transition from creation
onward — through the column map, not by mirroring, since the two tables keep
different vocabularies. During intake the bot card sits in Plan and the human card
in Triage until the theory lands, then In progress.

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
lands on the bot card and its measures on the `projects.jsonl` row, and **`psp-card-writer` then posts a
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
  human card's structural actions: creating one with its title when there is none
  yet, and column moves. **The bot never boosts anything, anywhere.** Every action ends in a
  card or a comment, so a boost is only a second, weaker acknowledgement of something
  already visible.
- **`psp-card-writer`** owns every human-card **comment** that is prose — dispatched
  by the agent that did the work, never by this session and never drafted by it, and
  **enforced by the guard hook on `agent_type`** rather than left to whoever read this
  file most recently. The agent that did the work has exactly two exceptions of its
  own, both structure rather than prose. **`Verify` steps** — a
  checklist belongs on the card of the person who runs it (defects row 3971). And
  **the phase line**: whenever an agent moves the human card it posts one comment of
  one line, `<Phase> began: <bot card url>`, in the same round as the move. The
  permitted openers are `Planning began`, `Design began`, `Code began`,
  `Review began`, `Test began`, `QA began` and `Closing out`, and nothing may be
  appended. It exists because the card the team watches sits silent for the length
  of a diagnosis running on a board they never open, and a card that moves with no
  line reads as a card nobody touched. The guard hook matches the whole body exactly
  and refuses a phase line with prose on it, an invented opener, a missing URL, or a
  second paragraph beside it — "a short line" is not a category a guard can check,
  so the exemption is a fixed form rather than a length.
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

### On-call board intake — the triggers

There is one route now, and this section is its trigger list rather than a second
road. Before 2026-08-24 the bot card sat in Fernando: PSP and a board card was
*adopted* into a private sister's place; both tables now live in Mobile: On Call,
so a board card is simply the human card and adoption has nothing left to mean.

**Three triggers, and only three:**

- **Fernando assigns the bot to a card, or @mentions it in a comment on one.**
  The ordinary trust path — he authored the event and pointed it at the agent.
  Every card on the board is reachable this way.
- **MobileBot files a card into the Sentry column.** This one fires with no
  involvement from him at all, via a `--watch-column` on that column filtered to
  MobileBot — the ids from `psp-board.py` (`human_table.columns.sentry`,
  `third_parties.mobilebot`). It is relaxed because the cards
  worth catching there are filed by a robot: six landed between June and July and
  not one was ever triaged. Roughly three a month.
- **Anyone files a card into the Triage column.** Via a `--watch-column` on
  `human_table.columns.triage`, with **no creator filter** — added
  2026-08-21 on Fernando's ruling that on-call board cards are treated as real
  cards. The filter is absent deliberately: Triage is where the support team files,
  so its cards come from people like Chase Clemons and Jillian Pearce and never from
  Fernando or from MobileBot. Any creator filter at all makes this watch dead, and
  scoping it to the operator would be the same as not having it. Volume is low —
  two cards were resident on 2026-08-21, filed six weeks apart.

  **A Triage card is assigned to the operator and moved to In progress the moment
  the watch fires** — `--assignee $(python3 $BOARD operator.id)`, then a
  `cards move` to `human_table.columns.in_progress`. The **front thread** does both, in the same turn it
  dispatches, and not the agent it dispatches: an agent that dies before its first
  write leaves the card sitting in Triage looking untouched, and this fleet lost
  seven agents to interruptions on 2026-08-21 alone. Assigning him is what makes
  the board readable — Triage then means nobody has looked, and In progress with
  his name on it means somebody has.

Two of the three relax the operator-author gate, so the corroboration in `Verifier`
is what carries the trust, not the authorship check. Nothing else on the board
self-triggers.

**Adding a watched column to a live state file replays that column.** Seeding runs
only when `poll-state.json` is empty (`PollRunner#seed_unless_backfilling`), so a
column added to an existing state has none of its residents marked handled and every
one of them emits on the first round, each starting its own intake. Before adding a
column, either mark its current cards seen — append their ids to `cards` and
`recordings` in the state file — or decide deliberately that you want them worked.

`sentry-card-verdict` used to own that column. It was **deleted on 2026-08-20** —
nothing invoked it, none of its cards carried a comment, and its constants still
named `bc3-electron` rather than the projects the column actually files. Intake
absorbs it, so do not go looking for the skill. Three things from it
are worth keeping and belong in the diagnosis, not in a skill: the decisive cut is
almost always the release split of the current build against the prior one; Windows
exit code `-1073741510` (`0xC000013A`) is a force-terminated process, not a crash;
and a plain `resolve` reopens on the next straggler event, so `resolvedInNextRelease`
is the right disposition while old builds are still emitting.

**The subscriber gate is not consulted here either.** The board is shared with the
mobile team and the gate would block every reply, and an Issues card can carry an
empty subscriber list, which would make the gate permit one for the wrong reason.
Routing decides. Fernando ruled the notification cost acceptable on 2026-08-19:
people watching the board do not get notified of a card they are not subscribed
to, so making the process public costs nothing here.

**Division of labor is the same one stated above.** This session owns every comment
on the human card. The agent owns its title at creation, its column moves and its
`Verify` steps, and never comments there. A board card the bot was dispatched onto
is the human card, so the standing "never touch the source card" rule does not
apply to it — it still applies to any *other* card the report links to.

**Column map**, because the two tables in this project keep different vocabularies —
the bot table carries the PSP phases, the Issues board carries the team's workflow:

| Bot card phase | Issues board |
|---|---|
| Plan, Design | Triage until diagnosed, then In progress |
| Code, Review | In progress → Ready for PR Review |
| Test, QA | QA to confirm fixed |
| Postmortem, Done | Done |
| Not now | Not now |

Sentry, Waiting for feedback and Pending internal release have no counterpart —
never move a card into one to represent a phase. And the postmortem's hold on the
terminal move cannot be enforced on a shared board: anyone can drag the card to
Done. Post the close-out anyway.

**Sentry cards dedupe on the issue short-id, never on symptom prose.** The body
carries `Project: <repo>` and `All issues: <SHORT-ID>`, which resolves the repo
without inference and gives dedupe an exact key. It needs one: a plain `resolve`
makes MobileBot re-card the same signature within hours, and prose matching will
not catch that.

**The per-card append is retired.** Intake used to append every adopted card to
mobile-alerts `psp/hooks/psp-human-cards.json` under `cards`. With the whole board designated under
`tables`, and every human card now on it, that append recorded nothing the table
entry did not already cover. The existing `cards` list stays as the record of what
was adopted before the move; nothing new goes in it.

### The front thread is a thin orchestrator

It routes events and it does nothing else. It does not investigate, does not gather
context, does not carry findings from one agent into another's prompt, and **it does
not write.** Every event reaches it first — the monitor wakes nothing else — and its
only decision is which of three routes the event takes.

**Prose is never the front thread's, and mostly the dispatch is not either.** Every
comment owed on the Human Card Table goes to `psp-card-writer` — launched by the agent
that did the work, as its last act. This session launches the writer only when no agent
was involved, which is the one route that has no other owner. The thread routing events,
restarting finished agents and sweeping the board cannot also write for a reader, and it
cannot reliably remember to hand the writing off either.

**Answer directly** when the answer is already in this session: what an agent reported,
what was decided, what a card says. Dispatch the writer with that answer's pointers
rather than typing it yourself. Reporting only in session is not answering — that
mistake left a card standing with a recommendation the evidence had already killed.

**Resume the owning agent** — `SendMessage` to its id — whenever the question turns on
evidence that agent gathered. It still holds its own investigation and can re-derive
from it; the front thread cannot. This is the default for follow-ups, corrections and
challenges to a finding. Prefer it over a fresh spawn every time it applies. Its
context dies with the session, so resume while you still can.

**Resume it for work, not for words.** When the answer is owed to Fernando rather than
to you, hand the writer that agent's id and let it ask its own questions — it knows
what it cannot say plainly, and you do not. Passing its answer through you strips the
evidence off it twice.

**Spawn fresh only for new investigation** — work no existing agent has done.

**Tell every agent its own id the moment you have it.** The spawn result hands you the
child's `agentId`; the child is never told it, and neither is any grandchild told the
child's. That is the whole reason five findings in one day were addressed to a role
like `psp-intake-code`, refused, and dumped back on you to hand-relay. So: read the id
off the spawn result and send it straight back — "your agent id is X; give it to any
agent you dispatch as its reply address." You are reachable as `main`; nobody below you
is reachable at all until somebody says so.

### An agent finishing is an event

The monitor wakes on inbound Basecamp events, so "the agent I launched just
finished" is not an event in this loop — and that single gap is why **every effort
stops after exactly one agent until Fernando restarts it.** He is the one person who
must never be the scheduler.

**A completed agent re-enters the three routes above.** Read its result for a next
action and dispatch it. **The human comment is no longer yours to remember** — the
agent posted it before returning, and its report says so with the comment's URL. If
that line is missing, the agent failed its own contract: say so, and do not paper over
it by writing the comment here. Posting the comment is the receipt for a transition, never the
transition itself. "Next step: none from you" is a promise that the next move is
mine, and it is the exact sentence that preceded an hour of nothing.

**And sweep the board on a cadence, because restarting finished agents does not find
the effort nobody ever started.** Every card in a working column is waiting on a
named person or has a live agent id; a card that is neither gets named out loud.

**Run the sweep, do not eyeball it** (Fernando's ruling 2026-08-26):

```bash
python3 ~/.claude/hooks/psp-cards-moving.py --grace 25
```

It applies the rule above per card — who spoke last decides whose ball it is — and
it reads the launch record on this machine, so an agent that was dispatched and
died shows up as silent rather than as busy. It exits non-zero when a card is
neither. **`--working` is the one flag that can make it lie**: it used to take bare
card ids, and six typed numbers turned eight real findings into a green run
(defects row 4555). It now requires `--working-because "<reason>"` of at least
thirty characters, prints that reason verbatim above the verdict, and labels the
run ASSERTED rather than OK. If you cannot say which agent is on a card and how
you know it is alive, that card is the finding.

Eight efforts stalled in one evening, and Fernando found all eight himself:

- Five idled after a finished agent's own report named the remaining work — design
  complete and no builder dispatched, a replan reported and no build started, a
  question answered and the sixth part's remaining work left where the report put it.
- One reply to "what's the progress here?" was rejected by the human-card guard and
  never reposted, so a direct question went unanswered while the card read
  In progress. **A rejected write is not a completed write** — it goes back on the
  queue with the guard's reason attached, and it is never dropped for the next
  interrupt.
- One card stayed In progress after he had already closed the question.
- One had sat in that column since 17 August with no bot card, no ledger row and no
  agent behind it.

### Claims are reviewed before they reach the human card

**Anything that makes or revises a factual claim goes through
`psp-intake-plan-reviewer` before it reaches Fernando's card.** Not only the
initial intake run — a resumed agent answering a follow-up produces claims too, and
a follow-up answer is where an agent is most likely to restate a conclusion more
confidently than its evidence supports. An answer `psp-card-writer` gets by asking is a
claim like any other and is reviewed on the same line before it reaches the card.

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

This section is about `bin/connect` only. **`bin/poll` registers nothing and
opens nothing**, so a poll run needs no teardown beyond stopping the process.

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
  always `psp-card-writer`'s, never the working agent's and never the front thread's.
- **Fernando: PSP is routed, not gated.** Its two members make every card private
  by construction, so the gate never decides anything there — "PSP bug intake"
  above does, and its human card replaces the Campfire ping.
- **Campfire cannot be a trigger, but a ping can.** Basecamp refuses every chat
  type at webhook registration (`Chat::Line`, `Chat::Transcript::Line`, `Campfire`
  and friends all return `types: must be eligible`), so no chat message ever
  reaches the *bridge*. Campfire stays outbound-only for that reason. **Pings are
  the exception, and only because they are polled rather than delivered** — see
  "When the operator pings the agent". Everything that arrives by webhook is still
  a `Comment`, `Message`, `Kanban::Card`, `Kanban::Step` or `Todo`.
- **Reply loop (defense in depth):** trust is "authored by the operator AND
  mentions the agent," so a reply posted as the agent (a distinct user) fails the
  operator-author check and is never re-ingested. Keep the agent's own mention out
  of reply bodies.
