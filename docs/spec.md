# basecamp-local-agent-connector — Spec

## Purpose

Manage local Claude Code agents from Basecamp. This project bridges Basecamp
webhooks to local Claude agents: you write a comment / message / card in
Basecamp that @mentions a real agent user (e.g. `@Clawdito`), and a background
Claude agent running on your machine picks it up, gathers context from Basecamp,
acts on it, and replies as that agent user.

The bridge has two halves:

1. **`bin/connect`** — a Ruby process that exposes a local webhook
   server to the internet (via Tailscale Funnel), registers it as a Basecamp
   webhook, filters + verifies incoming events, and prints trusted events to
   STDOUT.
2. **`/basecamp-connect` skill** — a Claude Code skill that runs the script, watches its
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

The connector distinguishes **two** Basecamp users:

- **Agent** — a real Basecamp user (e.g. `@Clawdito`) backed by a **local
  `basecamp` CLI profile** of the same name. It is the **mention target** (the
  connector only fires when this user is @mentioned) and the **reply identity**
  (replies post as it via `--profile <agent>`). The agent name is passed as the
  positional argument; the connector **validates the profile exists locally at
  startup** (`basecamp me --profile <agent>`) and aborts with setup guidance if
  not.
- **Operator** — the user allowed to *trigger* the agent. This is the
  anti-prompt-injection boundary: only events authored by the operator are acted
  on, so a third party who can comment cannot inject instructions. Defaults to
  the `basecamp` CLI default profile; override with `--operator <profile>`.

The agent must be a **different** user than the operator. Because replies are
posted as the agent, and the trust filter requires the *operator* to be the
author, agent replies are never re-ingested — this is the structural fix for the
reply feedback loop. The connector warns at startup if the two resolve to the
same user.

The author match is keyed on **email address**, not id. Basecamp has two id
spaces — a webhook's `creator.id` is an account-scoped **Person** id, while
`basecamp me` returns a global **identity** id; they differ for the same human.
The email address is consistent across both, so it is the reliable trust key.
The mention match looks for a mention attachment
(`application/vnd.basecamp.mention`) naming the agent.

---

## Project structure (rubygem layout)

The Ruby server and its supporting code are organized as a proper gem so logic
lives in `lib/` (testable, requireable) and `bin/` holds only thin executables.

```
basecamp-local-agent-connector/
├── basecamp_agent_connector.gemspec   # gem metadata + deps (stdlib-only runtime)
├── Gemfile                            # bundler entry (dev deps: minitest, rubocop-37signals)
├── Rakefile                           # test + lint tasks
├── .rubocop.yml                       # inherits 37signals house style (copied from bc3)
├── bin/
│   └── connect                        # executable shim → Connector (Basecamp + GitHub)
├── lib/
│   ├── basecamp_agent_connector.rb    # top-level require + version + autoloads
│   └── basecamp_agent_connector/
│       ├── version.rb
│       ├── connector.rb               # unified orchestrator: one funnel + one multi-route server
│       ├── command_runner.rb          # shared: runs subprocesses (the test seam)
│       ├── server.rb                  # shared: WEBrick server, path→handler routes, raw POST handler
│       ├── tunnel.rb                  # shared: Tailscale Funnel lifecycle (start/reset)
│       ├── emitter.rb                 # shared: NDJSON STDOUT writer
│       ├── basecamp/                  # Basecamp:: — the Basecamp webhook transport
│       │   ├── bridge.rb              #   one route: secret path, register webhooks, handler, teardown
│       │   ├── client.rb              #   thin wrapper over the `basecamp` CLI (JSON in/out)
│       │   ├── identity.rb            #   resolve a Basecamp identity by profile (agent / operator)
│       │   ├── webhooks.rb            #   register/delete webhooks across all projects
│       │   ├── event.rb               #   payload value object (kind, creator, recording)
│       │   ├── verifier.rb            #   authoritative Basecamp API verification
│       │   ├── pipeline.rb            #   pre-filter → dedup → verify → emit orchestration
│       │   └── boost_poller.rb        #   received-boosts feed poll (boosts have no webhooks)
│       └── github/                    # GitHub:: — the PR review-loop transport
│           ├── bridge.rb              #   one route: secret path + HMAC, register repo hooks, handler, teardown
│           ├── client.rb              #   thin wrapper over the `gh` CLI (JSON in/out)
│           ├── webhooks.rb            #   register/delete repo webhooks
│           ├── webhook_signature.rb   #   constant-time X-Hub-Signature-256 HMAC verify
│           ├── review_event.rb        #   pull_request_review payload value object
│           ├── review_verifier.rb     #   re-fetch the review + inline comments
│           └── review_pipeline.rb     #   verify signature → filter → dedup → re-fetch → emit
├── skills/
│   └── basecamp-connect/
│       └── SKILL.md                   # the /basecamp-connect skill (Component 2)
├── test/                              # minitest, mirrors lib/ structure
├── docs/
│   └── spec.md
└── README.md
```

The `/basecamp-connect` skill is itself a deliverable: a `SKILL.md` under `skills/basecamp-connect/`
(Claude Code project-skill format — YAML frontmatter with `name`, `description`,
trigger keywords, then the instructions). It is the human/agent entry point that
runs `bin/connect`, watches its STDOUT, and dispatches background agents per the
behavior in Component 2. Discovery follows the standard Claude Code mechanism
(e.g. a `.claude/skills` symlink to `skills/`).

- **Top-level module**: `BasecampAgentConnector`. Each file above defines one
  class/module under that namespace (e.g. `BasecampAgentConnector::Server`).
- **`bin/connect`** is a minimal shim — it adds `lib/` to the load path, requires
  `basecamp_agent_connector`, and calls `BasecampAgentConnector::Basecamp::CLI.start(ARGV)`.
  All real logic lives in `lib/` so it is unit-testable without spawning the
  process.
- **Runtime dependencies**: stdlib only (`webrick`, `json`, `securerandom`,
  `open3` for shelling out to `basecamp`/`tailscale`). Dev dependencies
  (minitest, rubocop) live in the Gemfile.
- The gem is not intended for publication to RubyGems.org — the structure is for
  organization and testability, run locally from a clone.

---

## Component 1: `bin/connect`

### Invocation

```
bin/connect @AGENT --project <project>... [--operator <profile>] [--types <types>] [--boost-poll <seconds>|--no-boosts] [--port <port>]
```

- `@AGENT` — the agent user / local profile name (e.g. `@Clawdito` or
  `clawdito`; the leading `@` is optional, lowercased to the profile name).
  Required. Validated against local profiles at startup.
- `--project` — Basecamp project (name, URL, or ID). **Required and repeatable.**
  Basecamp webhooks are per-project and there is **no account-level/global
  webhook** in the API, so at least one project must be named. The `basecamp`
  CLI resolves a project name or URL to its ID under the hood, so you can pass
  `--project "Queenbee"` directly.
- `--operator` — profile whose user is allowed to trigger (default: CLI default
  profile).
- `--types` — optional comma-separated Basecamp event types
  (default: `Comment, Message, Kanban::Card, Kanban::Step, Todo, Chat::Line`).
  `Chat::Line` selects Campfire coverage: bc3 excludes chat kinds from webhook
  relay entirely, so the bridge covers chat with an integrated poller (interval
  `--chat-poll`, default 15s) that runs each new line through the same
  authorizer + corroboration pipeline as webhook deliveries.
- `--boost-poll` / `--no-boosts` — boosts have no webhooks (a Boost is not a
  Recording and creates no Event in bc3), so the bridge polls the **agent's own
  received-boosts feed** (`/my/boosts.json`) for them on this interval (default
  60s); `--no-boosts` disables the boost trigger.
- `--port` — local port for the Ruby server (default: an unused high port).

### Startup sequence

1. **Resolve agent + operator** — validate the agent name maps to a usable local
   profile (`basecamp me --profile <agent>`); if not, exit with guidance to run
   `basecamp auth login --profile <agent>`. Resolve the operator identity
   (default profile, or `--operator`). If a token is expired, attempt `basecamp
   auth refresh` once before failing (no `login` attempted automatically). Warn
   if agent and operator resolve to the same user (reply-loop risk).
2. **Resolve projects** — the explicit `--project` list (required). Names/URLs
   are resolved to IDs by the `basecamp` CLI when registering. This is the
   project set to subscribe.
3. **Start the local HTTP server** — a minimal **WEBrick** (Ruby stdlib, zero
   dependencies) server on `127.0.0.1:<port>` accepting `POST /bc5/<secret>`.
   A random unguessable path segment is generated per run (defense-in-depth; see
   Security). All other paths return 404. **One server + one funnel + one secret
   path serve every project**; the payload's `recording.bucket.id` identifies
   which project an event came from. A chat-only run (`--types` reduces to
   chat entries alone) mounts **no** `/bc5` route at all — there is no inbound
   ingress to expose or forge.
4. **Expose via Tailscale Funnel** — `tailscale funnel <port>` publishes the
   server on the public internet at a stable `*.ts.net` HTTPS URL. `serve`
   (tailnet-only) is insufficient — Basecamp's servers must reach the endpoint,
   so `funnel` (public) is required. **Skipped entirely when nothing mounts an
   inbound path** (chat-only): no funnel, and no Tailscale requirement.
5. **Start the Campfire poller** — chat-typed `--types` entries start the
   integrated poller: discover each project's chats synchronously (so the
   readiness log reports the room count), then fetch on the `--chat-poll`
   interval from a background thread. The first fetch baselines: lines
   predating the poller are marked seen, later ones process as live — and
   nothing emits before the connector reports readiness. Runs before webhook
   registration so discovery never widens the register-to-listen window.
6. **Register webhooks** — for **each** project in the set, `basecamp webhooks
   create <funnel-url>/bc5/<secret> --project <project> --types <webhook types>`
   — the **webhook-eligible** types only; chat-typed entries went to the poller,
   and Basecamp would reject them. Skipped when no webhook types remain. Capture
   every created webhook ID for cleanup. Surface per-project registration
   failures without aborting the rest. Then start the **boost poller** (unless
   `--no-boosts`): it fetches nothing until its first interval pass, well after
   the readiness lines print, so no event can beat the funnel's consumer to the
   stream.
7. **Listen** — for each incoming POST, run the pipeline below. Always respond
   **200 OK quickly** (so Basecamp does not retry); filtering/verification/
   dispatch happen out of band.

### Event pipeline

For each delivered event:

1. **Cheap pre-filter** (on the raw payload, no API calls):
   - Path matches the secret path.
   - `kind` is a `*_created` **or** `*_content_changed` event (edits that add the
     mention count).
   - `creator.email_address` matches the **operator** (case-insensitive). Email,
     not id — a webhook's `creator.id` is an account-scoped Person id while
     `basecamp me` returns a global identity id; the email bridges them.
   - The event **targets the agent** — its content `@mentions` the agent (a
     mention attachment carrying the person's SGID, not literal `@name` text), or
     it assigns the agent, or it is a `comment_created` (which may target the
     agent by subscription; that can't be judged from the payload, so comments
     are admitted here and decided at verification).
2. **Dedup** — drop the event if its `event.id` has already been seen (in-memory
   set; at-least-once delivery means duplicates are expected). An id counts as
   seen once it reaches a verdict; an event Basecamp could not corroborate is
   forgotten again so a redelivery (or, for chat, the next poll) retries it —
   the fetch may have failed transiently, and re-verifying is idempotent.
3. **Authoritative verification** (the real trust gate): re-fetch the recording
   from Basecamp via the CLI (`basecamp show <recording.url|app_url>` /
   `basecamp ... -j`) and confirm it **actually exists** with the claimed creator
   and content. A forged POST (the funnel URL is public, Basecamp sends no
   signature) cannot survive this — if Basecamp doesn't corroborate the event, it
   is discarded. The payload's content field is never trusted directly; the
   fetched content is authoritative. For a **comment on a subscribed recording**,
   verification additionally re-fetches the parent's subscribers
   (`basecamp subscriptions show`) and stamps the agent's membership onto the
   authoritative event, so the subscription that triggers is the live one
   Basecamp reports, not a claim in the POST. For a **boost** there is no
   recording endpoint to re-fetch (a boost is not a Recording): verification
   re-fetches the **agent's own received-boosts feed** and requires the claimed
   boost id to be present with the claimed booster — the emitted booster,
   content, and boosted recording all come from that fresh fetch, and presence
   in the feed doubles as the targeting fact (stamped `agent_boosted`). The
   webhook route refuses boost-kind payloads outright: Basecamp never delivers
   them, so the poller is the sole boost source.
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
    "content": "<p>Hey <bc-attachment content-type=\"application/vnd.basecamp.mention\">…Clawdito…</bc-attachment> please ...</p>",
    "parent": { "id": 789, "type": "Kanban::Card", "app_url": "..." },
    "bucket": { "id": 222, "name": "BC5 Calendar", "type": "Project" }
  }
}
```

`app_url` / `url` and `bucket` are the handles the downstream agent uses to pull
full context and resolve the working repo.

A **boost** event (`"kind": "boost_created"`) is synthesized from the agent's
received-boosts feed rather than a webhook: `creator` is the **booster**,
`recording` is the boosted recording (the agent's comment/card/answer — no
`content` field in this feed representation), and `details.boost` carries the
boost's own `id` and `content` (up to 16 characters, e.g. `"🔥"` or `"redo"`).

---

## Component 2: `/basecamp-connect` skill

**Artifact**: `skills/basecamp-connect/SKILL.md` — a Claude Code project skill (YAML
frontmatter: `name: basecamp-connect`, `description`, trigger keywords; body: the
operating instructions below). This is a first-class deliverable of the project,
not just runtime glue.

### Invocation

```
/basecamp-connect @Clawdito --project "BC5 Calendar"               # one project
/basecamp-connect @Clawdito --project "BC5 Calendar" --project HEY  # several
```

`@AGENT` and flags pass through to `bin/connect`.

### Behavior

1. **Launch the bridge** — run `bin/connect @Clawdito --project ...`
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
      instruction is the recording's **raw HTML content with the agent mention
      removed** (the rest of the markup — links, other mentions — kept intact).
      Agents appear in the current Claude session. **No concurrency cap** — every
      trusted event is dispatched immediately.
   d. **Reply as the agent** — post results to the originating recording with
      `basecamp comment <recording> "<body>" --profile <agent>` so the reply is
      authored by the agent user:
      - **Success** — a results comment where the mention was written.
      - **Failure** (agent errors / can't complete) — a short error summary
        comment that **@mentions the operator (event creator)** so it surfaces as
        a notification. You always learn when a dispatch failed.
      Replying as the agent (a distinct user from the operator) is what stops the
      reply from re-triggering the connector.

---

## Webhook payload reference (from bc3)

Confirmed against `bc3` source (`app/views/api/webhooks/event.jbuilder`,
`app/views/api/recordings/_recording.json.jbuilder`,
`app/models/webhook/delivery.rb`, `app/models/webhook.rb`).

- **Top-level keys**: `id`, `kind`, `details`, `created_at`, `recording`,
  `creator`, (`copy` for copied events).
- **`kind`**: `"<container>_<action>"`, e.g. `comment_created`,
  `message_created`, `kanban_card_created`, `message_content_changed`. The
  connector subscribes to `*_created`, `*_content_changed`, and
  `*_assignment_changed` (assignment events carry `details.added_person_ids` /
  `removed_person_ids`).
- **`recording`**: `id`, `status`, `type` (Ruby class: `Comment`, `Message`,
  `Kanban::Card`, `Todo`, …), `title`, `url` (API JSON), `app_url` (browser),
  `bookmark_url`, `parent` {id,title,type,url,app_url}, `bucket` {id,name,type},
  `creator` (person), and **`content`** — the human-typed text. For rich-text
  types `content` is **HTML**; for `Todo` it's the plain todo title.
- **`creator`** (person): `id`, `name`, `email_address`, `personable_type`
  (`User`/`Client`), `admin`, `owner`, `client`, `employee`, `time_zone`,
  `avatar_url`, etc. `email_address` is the match key for the operator (the `id`
  here is an account-scoped Person id, distinct from the identity id returned by
  `basecamp me`).
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
| Watched projects | Explicit `--project` list (name/URL/ID), required | — (at least one) |
| Project→repo map | Maps Basecamp project names / app tokens to local repo paths under `~/Work/<org>/<repo>` | heuristic + ask-on-miss |
| Default event types | Subscribed Basecamp types | `Comment, Message, Kanban::Card, Kanban::Step, Todo` + `Chat::Line` (polled — chat has no webhooks) |
| Boost poll | Received-boosts feed poll interval (`--no-boosts` disables) | 60s |
| Local port | WEBrick bind port | unused high port |

---

## Code style

Follow Basecamp's house style — `~/Work/basecamp/bc3/STYLE.md` is the reference,
and bc3's `.rubocop.yml` is adopted as the lint baseline. This is a plain Ruby
gem (no Rails), so the Rails/Active Record sections don't apply, but the general
Ruby rules do:

- **No comments** unless they flag genuinely non-obvious behavior. The code
  should read on its own.
- **Expanded conditionals over guard clauses**, with the documented exceptions
  (early return at the very top of a method, or when the body is non-trivial).
  **No ternaries** — prefer `if`/`else`.
- **Method ordering**: class methods, then public methods (`initialize` first),
  then private. Order methods vertically by invocation order so the flow reads
  top-to-bottom.
- **Visibility modifiers**: no blank line under `private`; indent the methods
  beneath it. For a module that is all private methods, `private` at the top with
  a blank line after and no indent.
- **`!` suffix** only for methods with a non-bang counterpart — never to flag
  "destructive."
- **Fail fast and loud.** Don't paper over unexpected `nil`/missing state with
  `&.` or silent fallbacks; let it raise so bugs surface. (e.g. a missing
  webhook id on teardown is worth reporting, not swallowing.)

## Testing

We value tests highly and keep the code tight: **aim for ≥2 lines of test per
line of production code.** The bc3 testing philosophy (`STYLE.md` §Tests)
applies, adapted to a non-Rails gem:

- **Minitest only** — Ruby's stdlib `minitest`, no extra frameworks, helpers, or
  DSLs unless genuinely necessary.
- **One test file per class**, mirroring `lib/` under `test/` (e.g.
  `lib/basecamp_agent_connector/pipeline.rb` → `test/pipeline_test.rb`).
- **Test the public interface only** — never test private methods directly.
  Drive them through the public API so tests survive refactoring.
- **Group related assertions** in one test case rather than splitting every
  assertion into its own `test` block.
- **Never mock our own code.** The external boundary here is the **`basecamp` and
  `tailscale` CLI subprocesses** — that's the equivalent of HTTP in a Rails app.
  To make it testable without mocking our classes, the components that shell out
  (`basecamp_cli`, `tunnel`, `webhooks`) take an injectable **command runner**;
  tests pass a fake runner returning canned CLI output/exit status. Reach for
  Mocha only as a last resort, and never metaprogram stubs (`define_method`).
- **Test behavior, not implementation** — assert on emitted output and observable
  effects, not on internal structure.
- **Fake data** uses `example.com` / `example.org` for any URLs or emails.

Coverage the suite must include:

| Unit | What to assert |
|------|----------------|
| Mention matching | a mention attachment naming the agent matches; a mention of a different user does not; plain text naming the agent does not |
| Operator filter | events authored by the operator pass; events from any other user are dropped |
| Kind filter | `*_created` and `*_content_changed` pass; other kinds dropped |
| Dedup | a repeated `event.id` is dropped; distinct ids pass |
| Verification | corroborated event (CLI returns matching recording) dispatches; forged event (CLI says not found / mismatched creator) is rejected |
| Emitter | one well-formed NDJSON line per verified event |
| Webhooks | registers one webhook per project; teardown deletes all, continuing past a single failure and reporting it |
| Identity | expired token triggers a single `auth refresh`; still-failing exits with a clear message |
| Projects | explicit `--project` list honored; empty list enumerates all accessible projects |
| CLI/arg parsing | flags map to the right config; required `<trigger>` enforced |
| Boost poller | first fetch baselines without replaying history; a post-start boost emits once; an uncorroborated boost is retried while it stays in the feed; a full all-new page warns of possible overflow |

## Security considerations

- **Forged POST is the real threat**, not just a wrong author. The funnel URL is
  public and Basecamp sends no signature, so anyone could POST a payload claiming
  `creator = <operator>`. The author filter alone cannot stop this.
  **Mitigation: authoritative verification** — every event is re-fetched from
  Basecamp and only acted on if Basecamp corroborates it (existence + creator +
  content). A secret URL path is a cheap first gate on top.
- **Prompt injection** — payload text flows into an agent that can run commands.
  Two layers defend it: (1) only events authored by the **operator** (and
  @mentioning the agent) are acted on, and (2) the content is re-fetched from
  Basecamp (not taken from the POST body). Treat all content as untrusted
  regardless; keep agents scoped to the resolved repo.
- **Public endpoint hygiene** — the server only honors `POST /bc5/<secret>` and
  ignores everything else.
- **Teardown** — webhook + funnel are removed on exit, minimizing the window in
  which a public endpoint exists.

---

## Decisions resolved

- Trigger: a real @mention of the **agent** user (a local CLI profile of the
  same name, validated at startup), authored by the **operator** — **or** the
  operator **assigning** the agent a card/todo — **or** a new comment (authored
  by an authorized user) on a recording the agent **subscribes** to.
- Subscription trigger: a `comment_created` with no mention, when the agent is a
  subscriber of the comment's parent (the commented-on card/todo/message —
  subscriptions live on the container, not the comment). Corroborated by
  re-fetching the parent's subscribers (`basecamp subscriptions show`) and
  matching the agent's Person id; the author is gated exactly as a mention is
  (operator by default, else the active trust mode's authors), and the agent's
  own comments never re-trigger because its identity never authorizes.
- Boost trigger: someone boosts the agent's work. A boost never fires a webhook
  (not a Recording, no Event), so the bridge polls the **agent's own
  received-boosts feed** (`/my/boosts.json`, the report behind the "You've got
  Boosts!" notification) every `--boost-poll` seconds (default 60) and
  synthesizes a `boost_created` event per new entry. The booster is gated
  exactly as a mention author is (operator by default, else the active trust
  mode's authors; the agent's own boosts never authorize), corroboration is a
  fresh fetch of the same feed (claimed id present with the claimed booster;
  emitted booster/content/recording all from the fetch), and feed membership is
  the targeting fact. History is baselined by time, never dispatched; the feed
  is account-wide, so the bound is the agent's identity rather than the
  watched-project list. `--no-boosts` disables the trigger.
- Assignment trigger: the documented-but-previously-undocumented
  `todo_assignment_changed` / `kanban_card_assignment_changed` /
  `kanban_step_assignment_changed` events (bc3 PR #12156). Actionable when
  authored by the operator **and** `details.added_person_ids` includes the agent
  — corroborated by re-fetching the recording and confirming the agent is among
  its current `assignees` (the recording has no "who assigned" field, so the
  assigner identity rests on the operator-author check + the secret URL path,
  as with mentions). To receive them, the default subscribed types now include
  `Todo` and `Kanban::Step` (`Kanban::Card` already covered cards). The dispatched
  agent acknowledges by **boosting** the recording with `On it!` (the single ack
  for both triggers — boosts work on todos and cards too), then works the
  card/todo as the instruction.
- Reply: post results back **as the agent** (`basecamp comment --profile
  <agent>`). On failure, post an error summary that @mentions the operator.
- Dedup: in-memory, keyed on `event.id`; always 200-OK fast.
- Working dir: infer from project name (app token → repo); **ask interactively**
  on miss.
- Triggers: both `*_created` and `*_content_changed`.
- Mention match: a mention attachment (`application/vnd.basecamp.mention`) naming
  the agent — not a plain-text token.
- Instruction form: raw HTML content with the agent mention removed.
- Scope: `--project` is required (BC3 has no global webhook); repeatable for
  several projects. One funnel + one server + one secret path; one webhook
  registered per watched project. The `basecamp` CLI resolves project names to
  IDs.
- Lifecycle: tear down all webhooks + funnel on exit.
- Forgery defense: authoritative Basecamp API verification (+ secret URL path).
- Token expiry: auto `basecamp auth refresh` once at startup, then fail with a
  clear message (no auto `login`).
- Dispatch: in-session background agents.
- Concurrency: unbounded.
- Server: WEBrick (stdlib, zero deps).
