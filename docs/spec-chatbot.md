# basecamp-local-agent-connector — Chatbot transport (Spec)

## Purpose

A second, **chat-native** transport for the same product: **interact with a local
Claude agent from a Basecamp Campfire.** Instead of @mentioning a real agent
*user* in a comment/message/card and bridging Basecamp **webhooks**, you address
a Basecamp **chatbot** (an "Integration") in a project's Campfire, and it replies
in the chat.

The chatbot is an **implementation detail, hidden from the user** — just like
webhooks today. The connector creates it on startup and deletes it on teardown;
you never set one up or manage it. You open the project's Campfire and talk to
your agent.

This is an **additive** transport alongside the webhook one in [`spec.md`](spec.md),
shipped as a **separate `bin/chat-connect`** executable and its own skill. Chat is
a narrower, conversational surface (chat only — no cards/comments); the webhook
transport remains the way to act where work already lives.

---

## Decisions (resolved)

| Area | Decision |
|---|---|
| Codebase | **Separate `bin/chat-connect`** + its own skill (shares `tunnel`/`server` patterns) |
| Surface | **Shared project Campfire**; you address the bot by name |
| Bot identity | **Named after the connection** — `service_name = <name>_chatbot` (e.g. `clawdito` → `clawdito_chatbot`). Hyphens are invalid (`/\A\w+\z/`), so an underscore stands in. |
| Lifecycle | **Ad-hoc per session** — created on connect, deleted on teardown (webhook parity) |
| Non-operator commands | **Silently ignored** |
| Trust gate | **Secret command path + authoritative re-fetch** of the chat line (full parity with webhooks) |
| Conversation | **Independent per line**, each fresh agent reads chat history **since the last bot reply** |
| Long-task feedback | **Synchronous ack line, then async result** to `callback_url` |
| Output shape | **Adaptive** — short results inline; long results spill to a linked Basecamp doc |
| Repo ambiguity | **Ask back in the chat**; correlate the answer via **quote/reply** to the bot's question |
| Concurrency | **Unbounded concurrent**; each reply **quotes the command** it answers |
| Cancel | **A reserved `stop`/`cancel` command** kills in-flight agents for that chat |
| Agent powers | **Full operator-authorized actions** (repo work + Basecamp writes as the operator) |
| Failure | **Plain error line** in chat (no @mention) |

---

## Why a chatbot

The webhook transport carries weight the chatbot transport sheds:

- **No mention parsing.** Basecamp only calls our endpoint when the bot is
  addressed; the `command` field is already the plain-text instruction. The whole
  `application/vnd.basecamp.mention` / SGID / Person-id machinery in `event.rb`
  disappears.
- **No second user account.** The webhook "agent" must be a *distinct real
  Basecamp user* with its own authenticated CLI profile, separate from the
  operator. A chatbot is **not a user** — it is an integration the operator
  creates ad hoc. No agent login to provision, no "agent ≠ operator" rule.
- **No reply loop.** Chatbot replies post as `type: "integration"` lines and
  never re-invoke the command endpoint. The reason the webhook transport needs two
  users does not exist here.
- **Chat-native UX.** Conversational back-and-forth is the natural shape for
  "ask my agent something and get an answer."

What it gives up: **scope.** Chatbots live only in chat — no comment/message/card
triggers. For acting where work already lives, keep the webhook transport.

---

## How Basecamp chatbots work (grounded in bc3)

Confirmed against bc3 source: `app/models/integration.rb`,
`app/models/integration/command_delivery.rb`,
`app/views/api/chats/integrations/command.jbuilder`,
`app/controllers/integrations/chats/lines_controller.rb`,
`app/models/chat/publisher/integration_command.rb`,
`app/controllers/chats/lines_controller.rb`.

### The integration object

A chatbot is an `Integration` attached to a chat (Campfire transcript) in a
bucket:

- **`service_name`** — the bot's handle. Validated `/\A\w+\z/` (letters, digits,
  underscore — **no hyphens**) and unique within the account.
- **`command_url`** — our public endpoint. **Validated to be HTTPS and resolve to
  a public IP** (`RestrictedHTTP::PrivateNetworkGuard`) outside development — a
  Tailscale Funnel `https://*.ts.net` URL satisfies this directly.
- The integration **is a `Person`** with an unguessable **`access_key`** that is
  **write-only**: it can post chat lines but **cannot read** any bucket content
  (per the `lines_controller.rb#set_bucket` comment).

### REST surface (no dedicated CLI — use `basecamp api`)

The `basecamp` CLI has no chatbot commands, so the connector uses the existing
`basecamp api {get,post,delete}` passthrough:

```
GET    buckets/:bucket/chats/:chat/integrations.json          # list
POST   buckets/:bucket/chats/:chat/integrations.json          # create  {service_name, command_url}
DELETE buckets/:bucket/chats/:chat/integrations/:id.json      # destroy
```

### The trigger

A line addressed to the bot in the Campfire dispatches a command
(`chats/lines_controller.rb`). The dispatched `command` is the line's **plain
text** (`integration_command_text`). (A dedicated `integration_only?` ping chat,
where every line is a command, also exists in bc3 — we are **not** using it; we
use the shared project Campfire.)

### The command payload (POST to `command_url`)

From `command.jbuilder`. Headers: `Content-Type: application/json`,
`User-Agent: Basecamp Integration Command`, `X-Request-Id`. **No HMAC signature**
(same as webhooks). 30s timeout, max 1 MB response, no redirects
(`command_delivery.rb`).

```json
{
  "command": "the plain-text line addressed to the bot",
  "original": { "...": "the chat line recording, if present" },
  "creator": { "id": 123, "name": "Jorge Manrubia", "email_address": "jorge@example.com", "...": "person" },
  "callback_url": "https://3.basecampapi.com/<acct>/integrations/<access_key>/buckets/<bucket>/chats/<chat>/lines.json"
}
```

`creator` is the human who sent the line — **our operator-trust hook**.
`callback_url` is where we post replies (access-key-authenticated, no OAuth).

### Replying — two paths

1. **Synchronous**: the body we return from the `command_url` POST becomes a chat
   line immediately (`integration_command.rb`:
   `delivery.succeeded? ? delivery.response.body : delivery.error_message`). If
   our endpoint errors or times out, **Basecamp posts the error as a chat line**
   (e.g. "⚠️ Response code: 500") — free failure visibility for transport-level
   problems.
2. **Asynchronous**: `POST <callback_url>` with `{"content": "<html>"}`
   (`Unauthenticated`, access-key-authenticated). A body of `{"content":"ping"}`
   returns `pong`.

**Our pattern:** return 200 fast with a brief **ack line** ("On it 🍳") so we beat
the 30s timeout, then post the agent's real result asynchronously to
`callback_url` when the background agent finishes — mirroring today's "200 fast,
process out of band."

---

## Invocation

```
bin/chat-connect <name> --project <project>... [--operator <profile>] [--port <port>]
```

- `<name>` — a label for the connection; the bot is created as
  **`<name>_chatbot`** (e.g. `bin/chat-connect clawdito --project "BC5 Calendar"`
  → bot `clawdito_chatbot`). Must reduce to a valid `\w+` service name (hyphens
  are not allowed, so they collapse to underscores).
- `--project` — Basecamp project (name, URL, or ID). **Required and repeatable.**
  Each project's Campfire gets one bot.
- `--operator` — profile whose user is allowed to trigger (default: CLI default
  profile). There is **no agent profile** to provide — the bot is not a user.
- `--port` — local server port (default: an unused high port).

---

## Identity & trust model

| | Webhook transport | Chatbot transport |
|---|---|---|
| Agent identity | A real Basecamp user + authed CLI profile | An **ad-hoc integration** (no user, no login) |
| Reply identity | The agent user (`--profile <agent>`) | The bot, via `callback_url` access key |
| Operator | OAuth identity; only allowed trigger | OAuth identity; creates/deletes the bot, reads context, **and is still the only allowed trigger** |
| "Agent ≠ operator" rule | Required (reply-loop defense) | **Not needed** |

The operator collapses from *two real accounts* to *one OAuth identity + an
ad-hoc bot*. The **operator-trust boundary is preserved and is entirely our
job**: Basecamp delivers a command for *anyone* who addresses the bot, so the
connector checks `payload.creator.email_address` against the operator (the same
email-keyed check as `spec.md` §Identity) and **silently ignores everyone else** —
no reply, no log noise visible to the team.

Reading context still requires the operator's OAuth (the bot's access key is
**write-only**), so the background agent gathers context via the `basecamp` CLI,
and — because it acts **with full operator authority** — may also take Basecamp
write actions (create docs/cards/comments, open PRs) just as in the webhook flow.

---

## Hidden lifecycle (mirrors webhooks)

Ad-hoc per session — the bot only exists while you're connected.

- **On connect** — for each watched project: resolve its Campfire id
  (`basecamp chat list --project <p>`), then
  `basecamp api post buckets/<bucket>/chats/<chat>/integrations.json
  -d '{"service_name":"<name>_chatbot","command_url":"<funnel>/command/<secret>"}'`.
  Record each integration id. Print `Listening for @<name>_chatbot in N Campfire(s)`.
- **On teardown (SIGINT/SIGTERM)** — `basecamp api delete
  buckets/<bucket>/chats/<chat>/integrations/<id>.json` for each (best-effort,
  reporting failures); reset the funnel; stop the server. The bot disappears the
  moment you stop, like the webhooks do.

The public endpoint (Tailscale Funnel) is unchanged — already HTTPS/public, which
is exactly what `command_url` validation demands. Trade-off accepted: in a shared
Campfire the bot visibly appears and vanishes per session.

---

## Architecture: the gem

Same shape as the webhook transport — public endpoint → local server →
filter/verify → emit NDJSON → skill dispatches a background agent → reply — so the
patterns in `lib/` are reused, but it ships as its own executable:

- **`bin/chat-connect`** — thin shim → a chat-mode CLI.
- **`tunnel.rb`** — reused unchanged (still need a public HTTPS endpoint).
- **`server.rb`** — same WEBrick pattern; mount `POST /command/<secret>`, respond
  200 fast (with the ack-line body).
- **`chatbots.rb`** — new lifecycle class analogous to `webhooks.rb`:
  `register_all` creates one integration per project Campfire, `delete_all`
  destroys them, via new `basecamp api` methods on `basecamp_cli`.
- **`chat_event.rb`** — payload value object for a command: `command`, `creator`,
  `callback_url`, `original` (chat line), `bucket`/`chat`. **No** mention/SGID/kind
  logic.
- **`pipeline.rb`** — operator filter (`creator.email_address`) → dedup (chat line
  id) → authoritative re-fetch of the line → emit. Non-operator and unverifiable
  commands are dropped silently.
- **`verifier.rb`** — re-fetch the chat line/transcript via OAuth and confirm
  creator + content (forgery defense; same trust gate as webhooks).
- **`emitter.rb`** — emit the chat-command event, carrying `callback_url` and the
  `original` line id (so the agent can reply and quote).
- **`cli.rb` (chat mode)** — resolve operator (no agent profile); resolve project
  → Campfire; wire the `chatbots` lifecycle and signal-driven teardown.

### Event pipeline

1. Receive `POST /command/<secret>`; **respond 200 fast** with an ack-line body
   ("On it 🍳"), unless it's a reserved control word (below).
2. Parse the payload.
3. **Operator filter**: `creator.email_address` == operator (case-insensitive);
   **silently drop** otherwise.
4. **Dedup** by chat line id (`original.id`).
5. **Corroborate**: re-fetch the line via `basecamp` CLI; drop if Basecamp doesn't
   confirm creator + content.
6. **Emit** one NDJSON line: `{ command, creator, callback_url, chat, bucket,
   original }`.

### Control words

A command from the operator that is exactly `stop` / `cancel` (optionally scoped)
is a control signal: the skill **kills in-flight agents for that chat** rather
than dispatching new work. This requires the skill to track dispatched agent ids
per chat id.

---

## Skill behavior (`/chat-connect`)

Same dispatcher model as the updated webhook `SKILL.md` — the front thread is a
pure orchestrator that hands each event to a background agent and returns
immediately to watching. Chat-specific behavior:

1. **Per command event:**
   - **Reserved word** (`stop`/`cancel`): TaskStop the agents tracked for that
     chat; post a brief confirmation line. Do not dispatch.
   - Otherwise **resolve the repo** from the project (`bucket.name`), same mapping
     as today. **If ambiguous, ask back in the chat** — post a question line via
     `callback_url`; correlate the operator's **quote/reply** to that question to
     get the answer (a bounded clarify turn), then proceed.
   - **Dispatch one background agent** that owns the event end-to-end: it reads
     chat history **since the last bot reply** for context, gathers any needed
     Basecamp context via OAuth, does the work in the repo (with full
     operator-authorized powers), and replies. Track its id under the chat id (for
     cancel).
   - **Concurrency unbounded**: fire every command as it arrives.
2. **Reply** by `POST <callback_url>` `{"content":"<html>"}`:
   - **Quote the command** it answers (reply-to `original.id`) so interleaved
     concurrent results stay legible.
   - **Adaptive output**: short results inline; for anything substantial, create a
     Basecamp document and post a concise summary + link.
   - **Failure**: a plain error-summary line (no @mention).

---

## Trade-offs vs the webhook transport

| Dimension | Webhook transport | Chatbot transport |
|---|---|---|
| Surface | Comments, messages, cards | **Chat only** |
| Trigger | @mention attachment of agent user | Address the bot in the Campfire |
| Setup burden | Provision a second real user + login | **None** — ad-hoc bot, hidden |
| Reply identity | Agent user (OAuth profile) | Bot (write-only access key) |
| Reply loop | Needs agent ≠ operator | **N/A** |
| Mention parsing | SGID/Person-id matching | **None** (Basecamp gates it) |
| Context richness | Card/comment + thread + project | Thinner (chat history since last reply) |
| Failure visibility | We post an error comment | Plain error line; Basecamp also auto-posts transport errors |
| Read access | Operator OAuth | Operator OAuth (bot key is write-only) |
| Forgery defense | Authoritative re-fetch + secret path | **Same** (re-fetch + secret command path) |
| Multi-turn | One-shot per recording | Stateless per line + history; clarify via quote/reply |

---

## Security considerations

- **No signature** on the command POST (same as webhooks). Defenses: an
  unguessable `command_url` path (`/command/<secret>`, per run) as a first gate,
  **plus authoritative re-fetch** of the chat line via OAuth before acting.
- **Operator filter is mandatory and entirely ours.** Anyone in the Campfire can
  address the bot, so the `creator`-email check is the anti-prompt-injection
  boundary; non-operators are silently ignored. Run the bot in
  operator-controlled Campfires.
- **Bot key is write-only** — even if the `callback_url`/access key leaked, it
  cannot read Basecamp content, only post lines.
- **Prompt injection** — treat the `command` text and chat history as untrusted;
  keep the dispatched agent scoped to the resolved repo even though it carries
  operator authority.
- **Teardown** — the integration is deleted on exit, like the webhook,
  minimizing the window the public endpoint accepts commands.

---

## Implementation details to confirm

- **`callback_url` body shape** — confirm the default integration service's
  accepted field(s) (`{"content":...}` vs `{"line":{"content":...}}`) and
  `content_type` handling for rich-text/HTML replies.
- **Quote/reply correlation** — confirm the chat line reply-to/quote mechanism in
  the API used both to quote a command in the answer and to match the operator's
  reply to a pending clarify question.
- **Campfire resolution** — confirm `basecamp chat list` returns the chat id +
  bucket needed for the integrations endpoint (and behavior for projects with
  multiple rooms, via `--room`).
- **Service-name derivation** — map arbitrary `<name>` to a valid, account-unique
  `\w+` (`<name>_chatbot`, hyphens → underscores), and behavior if that name is
  already taken.
