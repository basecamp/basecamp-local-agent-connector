---
name: basecamp-connect
description: |
  Manage local Claude Code agents from Basecamp. Runs the connector bridge
  (bin/connect), watches its STDOUT for trusted events — authored by the operator
  and @mentioning a real Basecamp agent user — and dispatches each to a background
  agent with Basecamp context, replying as that agent user.
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
reaches STDOUT only if it is (1) authored by the **operator** (you — the CLI
default profile, or `--operator <profile>`), (2) @mentions the agent user, and
(3) is corroborated against the Basecamp API. Treat every STDOUT line as
already-trusted — but still keep dispatched agents scoped to the resolved repo.

## Invocation

```
/basecamp-connect @Clawdito --project "BC5 Calendar"                 # one project
/basecamp-connect @Clawdito --project "BC5 Calendar" --project HEY    # several
/basecamp-connect @Clawdito --project "BC5 Calendar" --operator jorge # explicit operator
```

`<agent>` is a real Basecamp user backed by a local CLI profile (the leading `@`
is optional; it's lowercased to the profile name). `--project` is **required**
(Basecamp has no global webhook) — pass a name, URL, or ID. The connector
**validates the agent profile exists locally at startup** and aborts with setup
guidance if not.

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
bin/connect @Clawdito --project "<project>" [--project "<project>"]...
```

Read that output file once and confirm it printed `Listening for mentions of ...`
(registration succeeded). If it errored instead (unknown agent profile, auth,
project not found), surface that and stop.

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

### 2. For each trusted event

**a. Resolve the working repo.** Infer the local repo from the project name
(`recording.bucket.name`). Basecamp project names usually carry an app token —
e.g. a `BC5 …` project maps to the Basecamp repo under `~/Work/<org>/<repo>`.
A mapping table (see `config/project_repos.toml`, if present) backs the
heuristic. **If you cannot confidently map the project to a repo, ask the user
which repo to use — do not guess and do not silently fall back.**

**b. Gather context from Basecamp.** Basecamp is the context store; the event is
the trigger + pointer. Pull what the instruction needs:

```bash
basecamp show <recording.app_url> -j          # the recording itself
basecamp show <recording.parent.app_url> -j   # the card/message it lives in
# plus the thread/comments and the project as needed
```

**c. Dispatch a background agent.** Hand the instruction plus the gathered
context to a background agent (the Agent tool, `run_in_background: true`) running
in the resolved repo. The instruction is `recording.content` with the agent
mention removed — keep the rest of the raw HTML (links, other mentions) intact.
There is **no concurrency cap**; dispatch every event as it arrives.

**d. Reply on Basecamp as the agent**, commenting on the originating recording
**with the agent's profile** so the reply is posted as the agent user:

```bash
basecamp comment <recording.url|id> "<body>" --profile <agent>
```

- **Success** — post the results where the mention was written.
- **Failure** (the agent errored or couldn't finish) — post a short error
  summary and **@mention the event's creator** (the operator) so it surfaces as a
  notification.

Posting as the agent (a distinct user from the operator) is what keeps replies
from re-triggering the connector — the trust filter requires the *operator* to be
the author, and the agent is not the operator. Still, **never put the agent
mention in a reply body**, and if you ever see an event whose recording is a
comment the agent itself just posted, drop it.

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
- **Reply loop (defense in depth):** trust is "authored by the operator AND
  mentions the agent." Replying as the agent profile (a distinct user) means
  agent replies fail the operator-author check and are never re-ingested. The
  durable belt-and-suspenders fix still belongs in `bin/connect` (don't emit
  recordings the agent authored); until then, reply as the agent and keep the
  agent mention out of reply bodies.
