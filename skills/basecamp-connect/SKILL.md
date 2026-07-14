---
name: basecamp-connect
description: |
  Manage local Claude Code agents from Basecamp. Runs the connector
  (bin/connect), which opens an outbound Agent Channel connection to Basecamp
  and streams the agent's durable dispatch inbox as NDJSON, then hands each
  dispatch off to a background agent that gathers context, does the work, and
  replies as that agent user, so the watcher thread stays free to keep taking
  new work.
  Invoked without arguments it recalls the last-used agent and connection from
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

The agent is a first-class **`Agent` personable** in Basecamp. It is identified
by a **local `basecamp` CLI profile** of the same name (e.g. profile `clawdito`),
which is its **reply identity** — replies post as the agent via `--profile
<agent>`. It connects to the **Agent Channel** with a per-(operator, agent)
**connection token**.

The trust model is now enforced **server-side by Basecamp**, not by this skill.
Basecamp only writes a dispatch to your partition when the event was authored by
you (an operator of the agent) and you have access to it, and it only ever
delivers your own partition over your connection. So every NDJSON line the
connector emits is already trusted — but still keep dispatched agents scoped to
the resolved repo.

Dispatches carry a **`reason`**: `mentioned` (incl. chat lines), `thread_reply`
(a reply on a thread the agent is subscribed to, no re-mention needed),
`assigned` (you assigned it a card/todo), or `watch` (a structural change on a
container it watches — card moved, todo added). All four are handled the same
way: gather context, do the work, reply.

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
/basecamp-connect                                                             # reuse last connection (confirm first)
/basecamp-connect @Clawdito --connection-token <token> --host <account-url>   # connect the agent account-wide
```

`<agent>` is the agent's local CLI profile (the leading `@` is optional; it's
lowercased to the profile name) and the reply identity. `--connection-token` is
the per-(operator, agent) token minted when you connect the agent in Basecamp;
`--host` is your account base URL (e.g. `https://3.basecamp.com/1234567`).
Delivery is **account-wide** — there is no `--project` and no per-project setup;
Basecamp addresses dispatches to the agent across every project you share with
it.

### Stored connection params (no-args invocation)

The skill remembers the last successful connection in
**`~/.config/basecamp-connect/last.json`**:

```json
{
  "agent": "clawdito",
  "host": "https://3.basecamp.com/1234567",
  "saved_at": "2026-07-01T15:00:00Z"
}
```

- **Invoked without arguments:** read that file and **confirm the stored params
  with the user before starting** — show the agent and host and ask whether to
  go with them or start fresh. Never launch on stored params silently. If the
  file doesn't exist, ask for the agent, connection token, and host. **Never
  write the connection token to the store** — it is a credential; keep it in the
  environment or prompt for it each time.
- **Invoked with arguments:** arguments win; the store is not consulted.
- **After a successful connection** (the `Connected …` line), write the agent
  and host back to the file (not the token) so the next no-args invocation can
  offer them back. Create the directory if needed. Launch failures must not
  overwrite it.

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

The agent's own replies never dispatch back to it: Basecamp excludes an actor
from the recipients of its own events, so the reply loop is closed server-side —
no distinct-user gymnastics required.

## Procedure

### 1. Launch the connector, then watch its STDOUT

`bin/connect` is a long-running process that never exits on its own — it opens
the Agent Channel connection and streams one dispatch per STDOUT line for as
long as it runs. A plain background task only notifies you when a command
*completes*, so on its own it would never wake you per event. You therefore need
**two** steps: run the connector in the background, then arm a persistent
monitor on its output so each new dispatch notifies you automatically — with no
user prompting in between.

**a. Run the connector in the background** and note the output-file path the
harness reports (you need it for the monitor):

```bash
cd ~/Work/basecamp/basecamp-local-agent-connector && \
  bin/connect @Clawdito --connection-token "<token>" --host "<account-url>"
```

Read that output file once and confirm the connection came up (a `Connected …`
line). If it errored instead (bad token, unreachable host), surface that and
stop. On success, **save the agent and host** to
`~/.config/basecamp-connect/last.json` (see "Stored connection params" above) —
**never the token** — so the next no-args invocation can offer them back.

**b. Arm a persistent monitor on that output file** with the Monitor tool
(`persistent: true`). Use `-n 0` so it reports only events that arrive *after*
this point, and filter to the NDJSON event lines so diagnostics stay out of the
stream:

```bash
tail -f -n 0 <connector-output-file> | grep --line-buffered -E '^\{'
```

Each notification the monitor delivers is one event — process it via step 2. An
event that lands while you are waiting on the user is **not** the user's reply.

Each STDOUT line is one trusted dispatch as NDJSON — the same shape the old
webhook path emitted, plus `dispatch_id` and `reason`:

```json
{"dispatch_id":55,"reason":"mentioned","event_id":99001,"kind":"comment_created",
 "created_at":"...",
 "creator":{"id":100,"name":"Jorge Manrubia","email_address":"jorge@..."},
 "recording":{"id":456,"type":"Comment","app_url":"...","url":"...",
   "content":"<p>Hey @Clawdito do X</p>",
   "parent":{...},"bucket":{"id":222,"name":"BC5 Calendar"}}}
```

`creator` is the operator (you). `reason` tells you why it arrived (`mentioned`,
`thread_reply`, `assigned`, `watch`). The connector acks each dispatch and
advances its cursor automatically, so a restart resumes cleanly from the durable
inbox. STDERR carries diagnostics — surface them but don't act on them.

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
- the **operator's** name/id (to @mention on failure).

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
     **@mention the operator** so it surfaces as a notification.
   - **Never put the agent mention in a reply body.**

Because the background agent gathers its own context and posts its own reply, the
front thread is free the instant it dispatches — it goes straight back to the
monitor, ready for the next dispatch while any number are in flight. There is
**no concurrency cap**; dispatch every one as it arrives.

**Keep a shared session and relay follow-ups to in-flight agents.** Run one
long-lived front thread across a work session rather than a cold start per
dispatch — you are usually working the same set of issues, and a shared session
context makes the whole thing cheaper and sharper. When a `thread_reply` (or a
new mention) lands for a thread whose background agent is **still working**,
relay the new information to that running agent (via SendMessage) instead of
spawning a fresh one — it keeps the subagent's context current, exactly as
Claude's subagent model is built to work. Spawn a new agent only for genuinely
new work.

**c. Loop prevention is automatic.** Basecamp never dispatches an actor's own
events back to it, so the agent won't be woken by its own replies. No client-side
self-authored filtering needed.

### When the agent is assigned a card/todo

If the dispatch `reason` is `assigned`, the operator assigned the agent to the
recording (a card/todo/step) — there's no mention to strip; **the recording
itself is the task**. The dispatched background agent should, in order:

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
   reasonable effort, reply with **what is failing** and @mention the operator —
   not a false "done."

#### Review / approval loop (GitHub webhook)

Once the PR is up and green, reviews are handled **event-driven via a GitHub
`pull_request_review` webhook**, not by an agent sitting in a poll loop: a human
review is unbounded latency, an idle LLM agent is the wrong tool for it, and an
in-session agent would die when the session ends. **`bin/connect` is unified** —
the same process that watches Basecamp over the Agent Channel can also watch
GitHub repos over a Tailscale Funnel when you pass `--repo`:

```bash
bin/connect @Clawdito --connection-token "<token>" --host "<account-url>" --repo <owner>/<repo>
```

It emits GitHub review events on the same STDOUT as Basecamp dispatches (a review
event carries `review_id`/`repo`/`state` instead of `recording`), so the one
persistent monitor you already armed picks them up too. GitHub still uses the
inbound funnel + webhooks (GitHub pushes to you) — only the Basecamp side moved
to the outbound Agent Channel. For a repo created
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

## Cleanup / lifecycle — always stop the process

The **Basecamp side auto-cleans by construction**: it holds nothing durable —
just the outbound Agent Channel connection and a short presence lease. Stop the
process and the connection drops, the lease lapses, and there is nothing public
and nothing registered to tear down. A restart resumes cleanly from the durable
inbox cursor.

The **GitHub side** (only when you passed `--repo`) still opens a public
Tailscale Funnel and registers repo webhooks; those must not outlive the
session. So the rule stays simple: **whenever you stop watching — normal end,
user interrupt, an error, or the skill aborting — stop the `bin/connect`
process** (TaskStop / send SIGTERM). Its teardown deletes the GitHub webhooks and
resets the funnel.

After stopping with `--repo` in play, **verify the GitHub side left nothing**:

```bash
tailscale funnel status   # expect no funnel for our port
```

If the process was `SIGKILL`ed with `--repo` active, reset the funnel manually
(`tailscale funnel reset`) and delete any leftover repo webhook. The Basecamp
Agent Channel needs no such cleanup.

## Notes

- The Basecamp side is account-wide over one Agent Channel connection — no
  funnel, no webhooks, no per-project setup. GitHub (with `--repo`) still uses
  one funnel + one server + one webhook per repo.
- Deliveries are authentic by construction: they arrive over a connection the
  agent opened and authenticated with its connection token. No forgery surface,
  no corroboration re-fetch. The dispatch is still a trigger + pointer — pull
  full context from the API.
- **Reply loop:** closed server-side — Basecamp never dispatches an actor's own
  events back to it. Still reply as the agent profile and keep the agent mention
  out of reply bodies.
