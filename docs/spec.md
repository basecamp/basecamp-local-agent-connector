# basecamp-local-agent-connector — Spec

## Purpose

Manage local Claude Code agents from Basecamp. This project bridges Basecamp
webhooks to local Claude agents: you write a comment / message / card in
Basecamp that mentions a trigger token (e.g. `@agent`), and a background Claude
agent running on your machine picks it up, gathers context from Basecamp, and
acts on it.

The bridge has two halves:

1. **`bin/start-basecamp-tunnel`** — a Ruby process that exposes a local webhook
   server to the internet (via Tailscale Funnel), registers it as a Basecamp
   webhook, filters + verifies incoming events, and prints trusted events to
   STDOUT.
2. **`/basecamp` skill** — a Claude Code skill that runs the script, watches its
   STDOUT, and dispatches each trusted event to an in-session background agent
   with full Basecamp context attached.

## Why this shape

Basecamp is an excellent place to *capture context* — a comment lives inside a
card, inside a project, with a creator, a thread, and linked recordings. Rather
than re-typing context into Claude, you write where the work already lives and
let the agent pull the surrounding context from Basecamp. The webhook payload is
treated as a *notification + pointer*, not as a source of truth (see Security).

---

## Identity model (the trust boundary)

The connector is bound to a single **linked Basecamp identity**. That identity
serves two roles at once:

- **Filter target** — the agent acts *only* on events authored by this identity.
  This is the anti-prompt-injection boundary: a third party who can comment in
  the project cannot inject instructions into the local agent.
- **Reply identity** — the agent posts results back to Basecamp *as* this same
  identity.

Resolution:

- **Default** — whatever account the `basecamp` CLI is currently authenticated
  as (today: `clawdito`). The Basecamp CLI supports multiple accounts/roles
  (`--account`, profiles); the connector validates against the default profile's
  user.
- **Configurable** — the linked identity can be set explicitly (by Basecamp user
  id and/or email) so you can point the connector at a dedicated operator role.
  A dedicated role (e.g. `clawdito`) used consistently for this channel keeps the
  filter target and the posting identity identical.

The linked identity's `user id` is the stable key used for the creator match;
email is a secondary signal.

---

## Component 1: `bin/start-basecamp-tunnel`

### Invocation

```
bin/start-basecamp-tunnel <trigger> [--project <project>...] [--types <types>] [--port <port>]
```

- `<trigger>` — text token to filter on, e.g. `@agent`. Required.
- `--project` — Basecamp project (name, URL, or ID). **Optional and repeatable.**
  If omitted, the connector watches **all projects the linked identity has access
  to** (auto-discovered via `basecamp projects -j`). Pass one or more `--project`
  to narrow.
- `--types` — optional comma-separated Basecamp event types
  (default: `Comment, Message, Kanban::Card`).
- `--port` — local port for the Ruby server (default: an unused high port).

### Startup sequence

1. **Resolve identity** — read the linked Basecamp identity (default: CLI-authed
   user). If the token is expired/invalid, attempt `basecamp auth refresh` once;
   if that still fails, exit with a clear message (no `login` attempted
   automatically).
2. **Enumerate projects** — the explicit `--project` list, or all accessible
   projects via `basecamp projects -j`. This is the project set to subscribe.
3. **Start the local HTTP server** — a minimal **WEBrick** (Ruby stdlib, zero
   dependencies) server on `127.0.0.1:<port>` accepting `POST /hook/<secret>`.
   A random unguessable path segment is generated per run (defense-in-depth; see
   Security). All other paths return 404. **One server + one funnel + one secret
   path serve every project**; the payload's `recording.bucket.id` identifies
   which project an event came from.
4. **Expose via Tailscale Funnel** — `tailscale funnel <port>` publishes the
   server on the public internet at a stable `*.ts.net` HTTPS URL. `serve`
   (tailnet-only) is insufficient — Basecamp's servers must reach the endpoint,
   so `funnel` (public) is required.
5. **Register webhooks** — for **each** project in the set, `basecamp webhooks
   create <funnel-url>/hook/<secret> --project <project> --types <types>`. Capture
   every created webhook ID for cleanup. Surface per-project registration
   failures without aborting the rest.
6. **Listen** — for each incoming POST, run the pipeline below. Always respond
   **200 OK quickly** (so Basecamp does not retry); filtering/verification/
   dispatch happen out of band.

### Event pipeline

For each delivered event:

1. **Cheap pre-filter** (on the raw payload, no API calls):
   - Path matches the secret path.
   - `kind` is a `*_created` **or** `*_content_changed` event (edits to add the
     trigger count).
   - `creator.id` matches the linked identity.
   - The trigger token appears in `recording.content` — matched **word-boundary,
     case-insensitive** (so `@agent` matches as a whole token, not inside
     `@agentsmith`), against the text with HTML stripped.
2. **Dedup** — drop the event if its `event.id` has already been seen (in-memory
   set; at-least-once delivery means duplicates are expected).
3. **Authoritative verification** (the real trust gate): re-fetch the recording
   from Basecamp via the CLI (`basecamp show <recording.url|app_url>` /
   `basecamp ... -j`) and confirm it **actually exists** with the claimed creator
   and content. A forged POST (the funnel URL is public, Basecamp sends no
   signature) cannot survive this — if Basecamp doesn't corroborate the event, it
   is discarded. The payload's content field is never trusted directly; the
   fetched content is authoritative.
4. **Emit** — print one NDJSON line to STDOUT with the verified event (see
   format below). Non-matching / unverified events are dropped (logged to
   STDERR).

### Shutdown (SIGINT / SIGTERM)

Tear everything down — no orphaned public endpoints or stale Basecamp webhooks:

1. Delete **every** registered webhook (one per watched project) via
   `basecamp webhooks delete`. Best-effort: keep deleting the rest even if one
   fails, and report any that couldn't be removed.
2. Stop the Tailscale Funnel for our port (`tailscale funnel reset` / scoped off).
3. Stop the WEBrick server.

The funnel + webhooks live only for the lifetime of the process; each run
re-registers fresh.

### Emitted STDOUT format

One JSON object per line (NDJSON), built from the **verified** recording:

```json
{
  "event_id": 99001,
  "kind": "comment_created",
  "created_at": "2026-06-28T12:00:00Z",
  "creator": { "id": 123, "name": "Clawdito", "email_address": "clawdito@37signals.com" },
  "recording": {
    "id": 456,
    "type": "Comment",
    "title": "...",
    "app_url": "https://3.basecamp.com/000/buckets/222/comments/456",
    "url": "https://3.basecamp.com/000/buckets/222/comments/456.json",
    "content": "<div>@agent please ...</div>",
    "parent": { "id": 789, "type": "Kanban::Card", "app_url": "..." },
    "bucket": { "id": 222, "name": "BC5 Calendar", "type": "Project" }
  }
}
```

`app_url` / `url` and `bucket` are the handles the downstream agent uses to pull
full context and resolve the working repo.

---

## Component 2: `/basecamp` skill

### Invocation

```
/basecamp @agent                       # watch all accessible projects
/basecamp @agent --project "BC5 Calendar"   # narrow to one (or more)
```

`<trigger>` and flags pass through to `bin/start-basecamp-tunnel`.

### Behavior

1. **Launch the bridge** — run `bin/start-basecamp-tunnel @agent --project ...`
   and tail its STDOUT. The skill watches continuously until the user stops it
   (which triggers the teardown above).
2. **Per trusted event** (one NDJSON line):
   a. **Resolve working repo** — infer the local repo from the project name. Basecamp
      project names carry an app token (e.g. a `BC5 …` project → the Basecamp
      repo under `~/Work/<org>/<repo>`). A configurable mapping table backs the
      heuristic. **If the project can't be mapped to a repo, ask the user
      interactively** which repo to use (do not guess, do not silently fall
      back).
   b. **Gather context** — pull the surrounding Basecamp context with the
      `basecamp` CLI: the recording itself, its `parent` (card/message), the
      thread/comments, and the project. Basecamp is the context store; the event
      is the trigger + pointer.
   c. **Dispatch an in-session background agent** — hand the instruction plus the
      gathered context to a background agent running in the resolved repo. The
      instruction is the recording's **raw HTML content with only the trigger
      token removed** (no HTML→text stripping — the agent sees the exact markup,
      including links/mentions). Agents appear in the current Claude session.
      **No concurrency cap** — every trusted event is dispatched immediately.
   d. **Reply** — post results back to the originating recording **as the linked
      identity** (default: clawdito), via `basecamp comment`:
      - **Success** — a results comment where the trigger was written.
      - **Failure** (agent errors / can't complete) — a short error summary
        comment that **@mentions the event's creator** so it surfaces as a
        notification. You always learn when a dispatch failed.

---

## Webhook payload reference (from bc3)

Confirmed against `bc3` source (`app/views/api/webhooks/event.jbuilder`,
`app/views/api/recordings/_recording.json.jbuilder`,
`app/models/webhook/delivery.rb`, `app/models/webhook.rb`).

- **Top-level keys**: `id`, `kind`, `details`, `created_at`, `recording`,
  `creator`, (`copy` for copied events).
- **`kind`**: `"<container>_<action>"`, e.g. `comment_created`,
  `message_created`, `kanban_card_created`, `message_content_changed`. The
  connector subscribes to `*_created` and `*_content_changed`.
- **`recording`**: `id`, `status`, `type` (Ruby class: `Comment`, `Message`,
  `Kanban::Card`, `Todo`, …), `title`, `url` (API JSON), `app_url` (browser),
  `bookmark_url`, `parent` {id,title,type,url,app_url}, `bucket` {id,name,type},
  `creator` (person), and **`content`** — the human-typed text. For rich-text
  types `content` is **HTML**; for `Todo` it's the plain todo title.
- **`creator`** (person): `id`, `name`, `email_address`, `personable_type`
  (`User`/`Client`), `admin`, `owner`, `client`, `employee`, `time_zone`,
  `avatar_url`, etc. `id` is the match key for the linked identity.
- **HTTP headers on delivery**: `Content-Type: application/json`,
  `User-Agent: Basecamp3 Webhook`, `X-Request-Id: <uuid>`. **No HMAC signature**
  — there is no shared-secret signature to verify, which is *why* authoritative
  API verification (not the payload) is the trust gate.
- **Delivery semantics**: at-least-once, up to 10 retries on non-2xx before the
  webhook is deactivated; redirects not followed. → respond 200 fast + dedup by
  `event.id`.
- **Scope**: per-bucket (= per-project). Type filtering possible but cannot be
  scoped narrower than a project. Limit: 50 active webhooks per project.

---

## Configuration

| Key | What | Default |
|-----|------|---------|
| Linked identity | Basecamp user id (+ email) for the filter target & reply identity | CLI-authed user (`clawdito`) |
| Watched projects | Explicit `--project` list, or all accessible | all accessible projects |
| Project→repo map | Maps Basecamp project names / app tokens to local repo paths under `~/Work/<org>/<repo>` | heuristic + ask-on-miss |
| Default event types | Subscribed Basecamp types | `Comment, Message, Kanban::Card` |
| Local port | WEBrick bind port | unused high port |

---

## Security considerations

- **Forged POST is the real threat**, not just a wrong author. The funnel URL is
  public and Basecamp sends no signature, so anyone could POST a payload claiming
  `creator = <linked identity>`. The creator filter alone cannot stop this.
  **Mitigation: authoritative verification** — every event is re-fetched from
  Basecamp and only acted on if Basecamp corroborates it (existence + creator +
  content). A secret URL path is a cheap first gate on top.
- **Prompt injection** — payload text flows into an agent that can run commands.
  Two layers defend it: (1) only events authored by the linked identity are
  acted on, and (2) the content is re-fetched from Basecamp (not taken from the
  POST body). Treat all content as untrusted regardless; keep agents scoped to
  the resolved repo.
- **Public endpoint hygiene** — the server only honors `POST /hook/<secret>` and
  ignores everything else.
- **Teardown** — webhook + funnel are removed on exit, minimizing the window in
  which a public endpoint exists.

---

## Decisions resolved

- Reply: post results back as the linked identity (default clawdito). On
  failure, post an error summary that @mentions the event's creator.
- Dedup: in-memory, keyed on `event.id`; always 200-OK fast.
- Working dir: infer from project name (app token → repo); **ask interactively**
  on miss.
- Triggers: both `*_created` and `*_content_changed`.
- Token match: word-boundary, case-insensitive.
- Instruction form: raw HTML content with only the trigger token removed (no
  HTML→text stripping).
- Scope: all accessible projects by default; `--project` narrows. One funnel +
  one server + one secret path; one webhook registered per watched project.
- Lifecycle: tear down all webhooks + funnel on exit.
- Forgery defense: authoritative Basecamp API verification (+ secret URL path).
- Token expiry: auto `basecamp auth refresh` once at startup, then fail with a
  clear message (no auto `login`).
- Dispatch: in-session background agents.
- Concurrency: unbounded.
- Server: WEBrick (stdlib, zero deps).
