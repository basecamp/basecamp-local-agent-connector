---
name: basecamp-connect
description: |
  Manage local Claude Code agents from Basecamp. Runs the connector bridge
  (bin/connect), watches its STDOUT for trusted, self-authored, trigger-matched
  events, and dispatches each to a background agent with Basecamp context.
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
You write `@agent do X` in Basecamp; a background agent on this machine picks it
up, gathers the surrounding context from Basecamp, and acts on it.

The trust model is enforced by `bin/connect`, **not** by this skill: only events
that are self-authored (by the linked Basecamp identity), trigger-matched, and
corroborated by the Basecamp API ever reach STDOUT. Treat every line on STDOUT
as already-trusted — but still keep dispatched agents scoped to the resolved
repo.

## Invocation

```
/basecamp-connect @agent --project "BC5 Calendar"               # one project
/basecamp-connect @agent --project "BC5 Calendar" --project HEY  # several
```

`--project` is **required** (Basecamp has no global webhook). Pass a project
name, URL, or ID — the `basecamp` CLI resolves it. The `<trigger>` and flags
pass straight through to `bin/connect`.

## Procedure

### 1. Launch the bridge

Run the connector in the background from the connector repo and tail its STDOUT:

```bash
bin/connect @agent --project "<project>" [--project "<project>"]...
```

Each STDOUT line is one trusted event as NDJSON:

```json
{"event_id":99001,"kind":"comment_created","created_at":"...",
 "creator":{"id":123,"name":"...","email_address":"..."},
 "recording":{"id":456,"type":"Comment","app_url":"...","url":"...",
   "content":"<div>@agent ...</div>","parent":{...},"bucket":{"id":222,"name":"BC5 Calendar"}}}
```

STDERR carries diagnostics (dropped/uncorroborated events, registration
notices) — surface them but don't act on them.

Keep watching until the user stops the skill. Stopping `bin/connect`
(SIGINT/SIGTERM) tears down every webhook and the funnel automatically.

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
basecamp show <recording.app_url> -j     # the recording itself
basecamp show <recording.parent.app_url> -j   # the card/message it lives in
# plus the thread/comments and the project as needed
```

**c. Dispatch a background agent.** Hand the instruction plus the gathered
context to a background agent (the Agent tool, `run_in_background: true`) running
in the resolved repo. The instruction is `recording.content` **with only the
trigger token removed** — keep the raw HTML (links, mentions) intact. There is
**no concurrency cap**; dispatch every event as it arrives.

**d. Reply on Basecamp** as the linked identity (default: clawdito), commenting
on the originating recording:

```bash
basecamp comment <recording.url|id> "<body>"
```

- **Success** — post the results where the trigger was written.
- **Failure** (the agent errored or couldn't finish) — post a short error
  summary and **@mention the event's creator** (`@First.Last`) so it surfaces as
  a notification.

## Notes

- One `bin/connect` run = one funnel + one server + one webhook per watched
  project. Re-running the skill re-registers fresh; exiting cleans up.
- Replies are posted by the linked identity. Follow the repo's attribution
  conventions for machine-generated content.
- The connector never trusts the POST body's content — it re-fetches the
  recording from Basecamp before emitting. The content you see on STDOUT is the
  authoritative copy.
