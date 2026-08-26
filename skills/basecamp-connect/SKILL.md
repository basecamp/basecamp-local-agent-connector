---
name: basecamp-connect
description: |
  Manage local Claude Code agents from Basecamp. Runs the connector bridge
  (bin/connect), watches its STDOUT for trusted events — authored by an authorized
  user (the operator alone, by default) and @mentioning a real Basecamp agent
  user — and hands each off to a background
  agent that gathers context, does the work, and replies as that agent user, so the
  watcher thread stays free to keep taking new mentions.
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
acts on it, and replies **as that agent user**.

The agent is identified by a **local `basecamp` CLI profile** of the same name
(e.g. profile `clawdito`). That profile is both:
- the **reply identity** — replies post as the agent via `--profile <agent>`, and
- the **mention target** — the connector only fires when that user is @mentioned.

The trust model is enforced by `bin/connect`, **not** by this skill: an event
reaches STDOUT only if it is (1) authored by an **authorized user** — by default
the operator alone (you — the CLI default profile, or `--operator <profile>`);
`bin/connect`'s trust flags (`--trust`, `--allow`, `--allow-domain`,
`--allow-project`) can deliberately broaden this to named colleagues, an email
domain, or the whole project membership — (2) **either** @mentions the agent
user **or** assigns it a card/todo, and (3) is corroborated against the Basecamp
API. The agent's own identity never authorizes, in any mode. Treat every STDOUT
line as already-trusted — but still keep dispatched agents scoped to the
resolved repo.

There are thus **two triggers**: an `@mention` of the agent, or the operator
**assigning** the agent a card/todo (a `*_assignment_changed` event whose
`details.added_person_ids` includes the agent — corroborated by re-fetching the
recording and confirming the agent is among its current `assignees`). Only the
**operator's** assignments count, in every trust mode, unless `bin/connect` was
started with `--allow-assignments-from-authorized`.

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
/basecamp-connect @Clawdito --project "BC5 Calendar" --allow marie@37signals.com  # + a named coworker
/basecamp-connect @Clawdito --project "BC5 Calendar" --allow-domain 37signals.com # any 37signals author
```

`<agent>` is a real Basecamp user backed by a local CLI profile (the leading `@`
is optional; it's lowercased to the profile name). `--project` is **required**
(Basecamp has no global webhook) — pass a name, URL, or ID. The connector
**validates the agent profile exists locally at startup** and aborts with setup
guidance if not.

**Who may trigger** defaults to the operator alone. Broaden it deliberately with
the trust flags — `--allow <email>`, `--allow-domain <domain>`, `--allow-project`,
or explicit `--trust <mode>` — and pass them straight through to `bin/connect`;
the bridge enforces them and logs the active set. See the connector README's
"Trust modes" for the full semantics and the agent-self / assignments-operator-only
safeguards.

### Stored connection params (no-args invocation)

The skill remembers the last successful connection in
**`~/.config/basecamp-connect/last.json`**:

```json
{
  "agent": "clawdito",
  "operator": null,
  "projects": [ { "id": 27, "name": "On Call" }, { "id": 41746046, "name": "BC5.1" } ],
  "trust": { "mode": "domain", "allow": [], "allow_domain": [ "37signals.com" ], "allow_assignments": false },
  "saved_at": "2026-07-01T15:00:00Z"
}
```

- **Invoked without arguments:** read that file and **confirm the stored params
  with the user before starting** — show the agent, the project list, **and the
  trust configuration (mode + the concrete allowed set)** and ask whether to go
  with them, adjust them (add/drop projects, different agent, change trust), or
  start fresh. Never launch on stored params silently. If the file doesn't
  exist, ask for the agent and projects as usual.
- **Invoked with arguments:** arguments win; the store is not consulted.
- **After every successful registration** (the `Listening for mentions of …`
  line), write the params that were actually used back to the file — agent
  profile, operator override (or null), the projects with their resolved ids and
  names, **and the trust configuration** (the mode and its value flags, so a
  later no-argument launch reconstructs the same trust boundary rather than
  silently falling back to operator-only) — so the store always reflects the
  last working connection. Create the directory if needed. Launch failures must
  not overwrite it.
- **Reconstructing the command from the store:** always emit **exactly one
  `--trust <mode>`** for the stored mode, followed by its value flags (`allow` →
  `--allow`, `allow_domain` → `--allow-domain`, `allow_assignments` → the
  assignment opt-in; `--trust project` needs no value flag). Emitting the mode
  explicitly makes `bare --trust domain` (empty `allow_domain`) reconstruct as
  `domain` — using the built-in default domain — rather than silently dropping
  to operator, and makes a value flag that disagrees with the stored mode (e.g.
  `mode:"operator"` with a stray `allow_domain`) get **rejected by the parser**
  rather than silently broadening trust. A missing `trust` block means
  operator-only (older stores). If the stored block is internally inconsistent
  and the parser rejects it, **stop and confirm with the user** — never infer a
  mode to make it launch.

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

If the agent profile resolves to the **same** user as the operator, **nothing
will trigger**: the connector refuses the agent's own identity in every trust
mode, so if the agent *is* the operator, the operator's own mentions are dropped
too. `bin/connect` warns about this at startup. Use a distinct bot account for
the agent.

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

`creator` is the **triggering author** — the person whose mention/assignment
drove this event. In the default operator-only mode that is always you; under a
broadened trust mode (`--allow`, `--allow-domain`, `--allow-project`) it may be
an authorized coworker instead. Treat `creator` as *the requester* — that is who
to @mention on failure — not as "the operator." The mention of the agent lives
in `recording.content` as a mention attachment. STDERR carries diagnostics
(dropped/uncorroborated events, registration notices) — surface them but don't
act on them.

Keep watching until the user stops the skill (see Cleanup).

### 2. For each trusted event — hand it off, don't do it yourself

**The front thread is an orchestrator, not a worker.** Its only job is to keep
watching for new mentions and to dispatch each one. It must **never** gather
context, run the requested work, or post the reply itself — every one of those
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
- the **agent profile name** (its reply identity);
- the **requester's** name/id — i.e. the event `creator` (to @mention on
  failure). This is the triggering author, who under a broadened trust mode is
  not necessarily the operator.

Instruct that background agent to, in order:

1. **Acknowledge immediately with a boost** — before any slow work, boost the
   originating recording (comment, message, card, **or** todo) with `On it!` **as
   the agent** so the trigger visibly registered (a boost is a lightweight
   reaction, ≤16 chars). This is the ack for **every** trigger — mentions and
   assignments alike:
   ```bash
   basecamp boost create <recording.url|id> "On it!" --profile <agent>
   ```
2. **Gather context from Basecamp** — it is the context store; the event is just
   the trigger + pointer:
   ```bash
   basecamp show <recording.app_url> -j          # the recording itself
   basecamp show <recording.parent.app_url> -j   # the card/message it lives in
   # plus the thread/comments and the project as needed
   ```
3. **Move the card out of Triage.** If the work lives on a card (the recording
   or its parent is a `Kanban::Card`), check which column it sits in. If it's in
   a **Triage**-like column and the card table has an **In progress**-like column
   (match loosely and case-insensitively: "In progress", "Working on", "Doing"),
   move the card there before starting — the board should show the work is
   underway:
   ```bash
   basecamp cards columns --project <project>            # find the columns
   basecamp cards move <card-id> --column "<In progress>" --profile <agent>
   ```
   If there's no Triage-like or no In-progress-like column, skip this silently —
   never invent columns.
4. **Do the requested work** in the repo.
5. **Reply on the originating recording as the agent** — commenting with the
   agent's profile so the reply posts as the agent user:
   ```bash
   basecamp comment <recording.url|id> "<body>" --profile <agent>
   ```
   - **Success** — post the results where the mention was written.
   - **Failure** (it errored or couldn't finish) — post a short error summary and
     **@mention the requester** (the event `creator`) so it surfaces as a
     notification for whoever asked — the operator in the default mode, or the
     authorized coworker who triggered it under a broadened mode.
   - **Never put the agent mention in a reply body.**

Because the background agent gathers its own context and posts its own reply, the
front thread is free the instant it dispatches — it goes straight back to the
monitor, ready for the next mention while any number of events are in flight.
There is **no concurrency cap**; dispatch every event as it arrives.

**c. Drop self-authored events.** If an event's recording is a comment the agent
itself just posted, ignore it. `bin/connect` already refuses agent-authored
events in every trust mode, and posting as the agent (a distinct user from the
operator) keeps replies from authorizing anyway — but this is cheap defense in
depth.

### When the agent is assigned a card/todo

If the event `kind` ends in `_assignment_changed`, the operator assigned the
agent to the recording (a card/todo/step) — there's no mention to strip; **the
recording itself is the task**. The dispatched background agent should, in order:

1. **Acknowledge first with a boost** — same as for a mention: boost the
   recording with `On it!` as the agent (`basecamp boost create <recording.url|id>
   "On it!" --profile <agent>`). Boosts work on todos and cards too, so a boost is
   the single ack for both triggers.
2. **Move the card out of Triage** — same rule as for mentions: if the assigned
   card sits in a Triage-like column and the table has an In-progress-like
   column, move it there before starting; skip silently otherwise.
3. **Do the work** the card/todo describes (its `content`/`title` is the
   instruction; gather context and resolve the repo as usual; if it's a PR task,
   follow the green-first lifecycle below).
4. **Reply with the result** on the same recording as the agent — and on failure,
   a short error summary that @mentions the operator.

The instruction here is the **card/todo content**, not a comment body. Everything
else (resolve repo, one background agent owns it end-to-end, front thread returns
to the monitor) is the same as above.

### Validate a finished body of work with `bin/ci` (in the background)

Whenever a coherent body of work is finished — the initial implementation, a
round of changes, a fix, a review-feedback pass — validate it by running the
repo's `bin/ci` **in the background** (non-blocking) before reporting done.
Aggregate as much as possible into a single run: don't re-run after every small
edit, but as a general rule run `bin/ci` once at the **end** of the body of work.
Running it in the background keeps the agent free and surfaces failures without
stalling; fix anything it flags before you reply "done."

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
5. **Only now reply "done"** on Basecamp, with the PR link. Never communicate
   success on a red or unchecked branch. If you cannot get it green after a
   reasonable effort, reply with **what is failing** and @mention the requester
   (the event `creator`) — not a false "done."

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
  push, and reply.
- **`approved`** — land per the repo's policy and reply done.

GitHub webhooks carry an HMAC secret (`X-Hub-Signature-256`), so unlike Basecamp
deliveries they are verified cryptographically *and* corroborated by an API
re-fetch. The connector-side plumbing that backs this loop (the unified
`Connector` + the GitHub `Bridge` route: register the repo hook, verify the
signature, parse `pull_request_review`, emit) is specced in
[`docs/pr-review-loop.md`](../../docs/pr-review-loop.md).

## Cleanup / lifecycle — always tear down

`bin/connect` opens a **public** Tailscale Funnel URL and registers a **real
Basecamp webhook per project**. These must not outlive the session. The
connector deletes every webhook and unmounts its own funnel paths on
`SIGINT`/`SIGTERM`, so the rule is simple: **whenever you stop watching — normal end, user interrupt, an
error, or the skill aborting — stop the `bin/connect` process** (TaskStop / send
SIGTERM). Its teardown does the rest.

After stopping, **verify nothing leaked**:

```bash
basecamp webhooks list --project "<project>" -j   # expect zero from this run
tailscale funnel status                            # expect no /bc5/… or /gh/… path
```

If the process was killed un-gracefully (e.g. `SIGKILL`) and teardown didn't run,
delete the leftover webhook(s) manually with `basecamp webhooks delete <id>
--project "<project>"` and unmount each leftover path with `tailscale funnel
--set-path /bc5/<secret> off`. Never run `tailscale funnel reset` — it tears
down every path on this host's funnel, including ones other tools mounted. Never
leave a registered webhook or a mounted path behind.

## Notes

- One `bin/connect` run = one or two paths on the host's shared funnel + one
  server + one webhook per watched project. Re-running re-registers fresh;
  exiting cleans up.
- The connector never trusts the POST body's content — it re-fetches the
  recording from Basecamp before emitting. The content you see on STDOUT is the
  authoritative copy.
- **Reply loop (defense in depth):** trust is "authored by an authorized user
  AND mentions the agent," and `bin/connect` refuses agent-authored events
  outright in every trust mode (matched by email and Person id). Replying as
  the agent profile (a distinct user) means agent replies are never
  re-ingested; still keep the agent mention out of reply bodies as a courtesy.
