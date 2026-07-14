# Built-in agent support in Basecamp

## Purpose

The connector in this repo proved the idea: you @mention an agent user in
Basecamp, a Claude agent on your machine picks it up, works with full Basecamp
context, and replies in place. It works — but every piece of it is a workaround
for something Basecamp doesn't provide. This document proposes what Basecamp
(BC5) should build so the approach is native, with all of today's limitations
removed.

It is a high-level design document: recommendations, alternatives, and
trade-offs. No implementation detail beyond what's needed to show each idea is
grounded in the current codebase.

The two headline recommendations:

1. **An `Agent` personable type** — a first-class kind of person for AI agents.
2. **The Agent Channel** — a dedicated, connection-oriented delivery mechanism
   built for agents, replacing webhooks for this use case entirely.

---

## What the connector has to work around today

Every mechanism in the connector maps to a gap in Basecamp. The catalogue,
each traced to its root cause in the source:

| # | Limitation | Root cause in bc3 |
|---|-----------|-------------------|
| 1 | **Per-project watch lists.** `--project` is required and repeatable; one webhook registered per project. | Webhooks are strictly per-bucket (`Bucket::Webhookable`); there is no account-level subscription of any kind. |
| 2 | **No chat.** You cannot drive the agent from Campfire at all. | Chat events are hard-excluded from webhooks (`Webhook.relay_to_matches_later`: `event.kind !~ /^(chat\|relay)/` — "chat is high volume and will have its own API"). That API never came. |
| 3 | **The agent is a full human user account.** A real login, a Launchpad identity, a seat. | The existing bot type (`Integration`) can't be mentioned (excluded from `reachable_people`), can't receive notifications (`Person#reachable?` is `user? \|\| client?`), can't read anything (its access key only authorizes posting chat lines), and can't authenticate via OAuth (OAuth always resolves through a human `SignalId::Identity` → `User`). Only a full `User` can do what an agent needs. |
| 4 | **Public inbound endpoint required.** Tailscale Funnel publishes the laptop to the internet just to receive events. | Webhooks are push-to-URL; there is no way for an external consumer to connect *out* to Basecamp and receive events (Action Cable exists but is first-party-only and UI-shaped). |
| 5 | **Forgeable deliveries.** Every event must be re-fetched and corroborated against the API before it's trusted. | Webhook deliveries carry no HMAC signature or shared secret. |
| 6 | **Manual lifecycle, orphan risk.** Webhooks and the funnel must be registered at start and torn down at exit; a SIGKILL leaves live public endpoints and stale webhooks behind. Webhooks also silently deactivate after 10 failed deliveries. | Webhooks are durable registrations with no lease, no TTL, no self-expiry, and no deactivation notice. |
| 7 | **No conversation.** If the agent asks a question in a thread, your plain reply doesn't reach it — you must re-mention it every time. | Mentions already auto-subscribe the mentionee to the thread, and subscribers are already notified of every new comment — but those notifications only go to email/push/web for `reachable?` people. Nothing exposes a person's notification stream to a machine consumer (there is no notifications-inbox API at all). |
| 8 | **Client-side filtering of a project-wide firehose.** The webhook delivers every event of the subscribed types in the project; operator-author and mention-of-agent checks happen on the laptop. | Webhooks can filter by recording type only — not by addressee, not by author. |
| 9 | **No structural events for boards and lists.** Watching "a card moved into this column" or "a todo was added to this list" means diffing generic recording events client-side. | Events for these transitions exist internally, but webhooks expose them as a per-project type-filtered stream, not as something a consumer can subscribe to per-container. |
| 10 | **Two id spaces, joined by email.** A webhook's `creator.id` is an account-scoped Person id; the CLI's `me` returns a global identity id. The connector matches operators by email address. | Person vs. Identity duality with no stable common key surfaced in both places. |
| 11 | **Trust policy lives in the client.** "Only the operator may direct the agent" is enforced by the connector, invisibly to Basecamp. Anyone in the project can @mention the agent and simply gets silently ignored. | Basecamp has no concept of who is allowed to direct an agent, because it has no concept of an agent. |

---

## Design principles

Distilled from what the experiment taught us:

- **Dedicated, not repurposed.** Webhooks are a generic integration surface
  with the wrong shape for this (push-to-URL, per-project, unsigned, durable
  registrations). Agents deserve a purpose-built mechanism — simple, efficient,
  and suitable — rather than more flags bolted onto webhooks.
- **Person-centric addressing, not project-centric plumbing.** The unit of
  delivery is "something addressed to this agent" — a mention, a thread reply,
  an assignment, a watched-container change — across the whole account. The
  server does the filtering; the agent never sees a firehose.
- **The agent connects out; Basecamp never calls in.** No public endpoint on
  the operator's machine, no funnel, no forgery surface — events arrive over a
  connection the agent opened and authenticated.
- **Auto-cleaning by construction.** Nothing durable is registered. Live
  delivery exists exactly as long as the connection (or a short renewable
  lease); when the agent process dies, its presence lapses on its own. There
  is nothing to tear down and nothing to orphan.
- **Reuse Basecamp's social model.** Mentions, subscriptions, assignments, and
  notifications already encode "who should hear about this." Agents should
  plug into that machinery as people, not bypass it with a parallel system.
- **Trust is Basecamp's job.** Who may direct an agent is account
  configuration, enforced server-side — not a client-side filter.

---

## Recommendation 1: the `Agent` personable type

Basecamp already has the right pattern: `Person` delegates to a personable
(`User`, `Client`, `Outsider`, `Integration`, `Tombstone`, `DummyUser`). Add
**`Agent`** — a person that represents an AI agent. This is worth doing
regardless of the delivery mechanism.

What an Agent person **is**:

- **Mentionable** — included in mention candidates and people pickers, so
  `@Clawdito` works everywhere mentions work, *including rich-text chat lines*
  (chat's rich-text lines already permit mention attachments today; the only
  blocker is that non-User people are excluded from the candidates).
- **Reachable and subscribable** — it can be a notification recipient and a
  thread subscriber, which is what powers conversation (see the Channel below).
- **Assignable** — a valid assignee for todos and cards, and a valid
  participant in pings/Campfires.
- **Attributable** — its actions (comments, boosts, card moves) are authored
  by it, with a distinct bot-style avatar and an "agent" badge in the UI so
  nobody mistakes it for a human.
- **Owned and governed.** An agent belongs to (at least) one human — its
  operator(s). Only operators can direct it (see trust, below). Admins manage
  agents in Adminland, like integrations today.

What an Agent person **is not**:

- **Not a seat.** Excluded from per-seat billing and user limits, exactly as
  `Integration` people are today (naturally: it isn't a `User`, and billing
  counts users).
- **Not a Launchpad identity.** No login, no password, no session. It
  authenticates with an **agent token** (the `access_key` on Person is the
  existing precedent), scoped to act as that person via the normal API. This
  removes the fake-human-account setup, the OAuth dance for a bot, and the
  dual id-space confusion — the agent has exactly one id, its Person id.
- **Not omnipotent.** Normal project access rules apply: it sees the projects
  it's been granted access to, and its API surface can be scoped tighter than
  a user's (e.g. no Adminland, no people management).

**Trust model, in product.** Each agent carries a directive policy: *who may
direct it* (a set of people, defaulting to its operator/creator). Mentions,
assignments, and thread replies from anyone else don't get delivered — or get
delivered flagged as unauthorized, at the operator's choice. This moves the
connector's operator filter into Basecamp, where it's visible, auditable, and
enforced before delivery rather than after.

**Why not extend `Integration` instead?** Integration is deliberately a
write-only chat bot: unmentionable, unreachable, no read access, tied to a
synchronous public `command_url`. Retrofitting agent semantics onto it would
change its meaning everywhere it's already special-cased, and its
one-per-service-name, admin-created, account-wide shape doesn't match "my
personal coding agent." A fresh personable type is cleaner and lets
Integration stay what it is.

---

## Recommendation 2: the Agent Channel

A dedicated delivery mechanism for agents, replacing webhooks in this role.
Two halves: a **durable inbox** and a **live stream** over one connection.

### The shape

- The agent's runtime (the connector's successor — ultimately just the
  `basecamp` CLI) opens an authenticated connection to Basecamp — one
  connection per agent, account-wide — and receives **agent events** as they
  happen. Transport is an implementation choice (Action Cable already carries
  authenticated per-user streams; SSE or long-poll would also do); the contract
  is what matters: *the agent connects out, authenticates with its agent
  token, and receives structured JSON events addressed to it.*
- Behind the connection sits a **per-agent inbox**: a durable, ordered queue of
  the agent's events with a cursor. The live connection is just the wake-up;
  on reconnect the agent resumes from its cursor and misses nothing. Events
  are acknowledged (or simply cursor-advanced), and expire after a retention
  window. This mirrors what `Notification` records already are — the inbox is
  essentially the agent's notifications, made consumable by a machine.
- Replies and actions go through the **existing REST API**, authenticated as
  the agent. No new write surface is needed — the experiment already proved
  the API covers comments, boosts, card moves, and uploads.

### What gets delivered

Everything is **addressed to the agent** — the server filters, the agent never
subscribes to projects:

1. **Mentions** — any recording, any project the agent can access, *including
   chat lines and pings*. Chat's webhook exclusion is irrelevant here: this
   rides the mention/notification path, not the event-relay-to-webhooks path,
   and its volume is inherently bounded (only lines addressing the agent).
2. **Thread replies without re-mention** — the conversational requirement.
   Basecamp already does the hard part: a mention auto-subscribes the
   mentionee to the thread, and every new comment notifies subscribers. If the
   agent is subscribable and its notifications feed the inbox, then once you
   mention it (or it comments), it's in the conversation — your plain reply
   reaches it like it would reach a human. Ping rooms give the same for chat:
   every line in a room the agent participates in is addressed to it (the
   existing integration-only ping behavior is the precedent).
3. **Assignments** — the agent is assigned a todo or card; the event carries
   who assigned it.
4. **Container watches** — the agent (or its operator, on its behalf) watches
   a card table, a specific column, or a todolist; it then receives structural
   events: card moved into/out of a column, todo added or completed. This is
   what turns a board into an automation surface — "anything landing in the
   *Ready for agent* column gets worked" — with no client-side diffing.
   Watches are the one *stated* interest (beyond implicit subscriptions), and
   they belong to the agent's profile, visible in the UI on the container
   ("Clawdito is watching this column").
5. **Directive gating baked in** — events from people outside the agent's
   directive policy are filtered (or flagged) server-side before delivery.

Each event is a **trigger plus pointer**, exactly as the connector treats
webhooks today: enough to know what happened and where, with URLs to pull full
context via the API. That division of labor worked well and keeps events small.

### Why it's trustworthy

- Deliveries arrive over a connection the agent opened, on an authenticated
  session — there is no public endpoint to forge a POST against. The entire
  corroboration re-fetch machinery becomes unnecessary (though re-fetching for
  *context* remains the normal pattern).
- The directive policy is enforced server-side, so "who can command my agent"
  is not a client-side convention.
- Loop prevention is structural and server-side: an actor's own actions never
  generate events back to itself (the notification machinery already excludes
  the creator from recipients).

### Why it auto-cleans

Nothing about the channel is a durable registration:

- **Live delivery is the connection.** Process dies → connection drops →
  nothing is left listening, nothing public exists, nothing must be deleted.
  The inbox keeps accumulating within its retention window, so a restart
  resumes cleanly — or the operator lets it lapse with zero residue.
- **Presence is a lease.** While connected (or renewing a short-TTL lease),
  the agent shows as *active* — in the UI, people can see the agent is
  actually listening before they mention it (a real papercut today: you write
  to an agent whose laptop is asleep and nothing happens). Lease lapses →
  agent shows *offline*. Optionally, mentioning an offline agent warns you.
- **Watches are profile state, not endpoints.** A watch left behind by a dead
  process delivers into the inbox harmlessly and is visible and revocable in
  the UI — unlike an orphaned webhook posting to a dead funnel URL until it
  silently deactivates.

Contrast with today: the connector must delete N webhooks and reset a public
funnel on every exit, and a SIGKILL leaves both behind.

### Why dedicated beats extending webhooks

Webhooks optimize for the opposite of every requirement here: they push to a
public URL (agents want to connect out), they're per-project (agents want
account-wide, addressee-filtered), they're unsigned (agents need
authenticity), they're durable registrations (agents want ephemerality), and
they're type-filtered firehoses (agents want "addressed to me"). Fixing all
five would be a bigger change to webhooks than a purpose-built channel — and
would still saddle agents with webhook semantics (retries, deactivation,
delivery logs) designed for server-to-server integrations. Keep webhooks for
what they're good at; give agents their own thing.

---

## How the limitations dissolve

| Today | With Agent + Channel |
|-------|----------------------|
| `--project` watch lists, one webhook per project | Account-wide, addressed delivery; zero configuration per project |
| No chat | Chat mentions and ping rooms delivered like everything else |
| Agent is a fake human account with a seat and a login | `Agent` personable: no seat, no login, one token, one id |
| Tailscale Funnel / public endpoint | Agent connects out; no inbound surface at all |
| Unsigned deliveries + corroboration re-fetch | Authenticated connection; deliveries are authentic by construction |
| Register/teardown lifecycle, orphaned webhooks and funnels | Connection + lease; nothing durable, nothing to clean |
| Re-mention on every reply | Subscription-based conversation, like a human |
| Client-side operator filtering | Server-side directive policy, visible in product |
| Client-side diffing for board/list automation | First-class container watches with structural events |
| Person id vs. identity id, joined by email | One id: the agent's Person id |

---

## Alternatives considered

**A. Account-level webhooks + HMAC signing + addressee filters.** The
incremental path: add a global webhook scope, sign deliveries, filter by
"mentions/assigns person X." Rejected as the primary mechanism: it still
requires a public inbound endpoint and durable registrations with manual
teardown — the two worst properties of the current setup — and still can't
carry chat without revisiting the volume exclusion. Signing deliveries is
worth doing anyway for the existing webhook feature, independent of agents.

**B. A notifications-inbox API (polling).** Expose a person's notification
stream via REST and let a bot poll it. Dramatically simpler than a streaming
channel and would already enable conversation (notifications cover mentions
*and* subscribed-thread replies). Rejected as the end state — polling latency
and cost are wrong for an interactive agent, and it doesn't cover container
watches — but it is a **sensible first milestone**: the durable inbox half of
the Channel, shippable before the streaming half, useful forever after as the
reconnect/catch-up path.

**C. Reuse Action Cable as a trusted OAuth client.** The infrastructure for
authenticated per-user streams already exists. But today's channels are
UI-shaped (rendered HTML partials, Turbo refresh signals) and first-party
gated; an agent needs a stable, versioned JSON contract. Verdict: fine as the
*transport* under the Agent Channel, wrong as the *interface*. Don't expose
UI channels to agents; define an agent-specific channel with an API contract.

**D. Extend the Integration/chatbot system.** Covered above — Integration is
write-only chat plumbing with a synchronous public callback, and its
constraints (unmentionable, unreachable, no reads, public `command_url`) are
the opposite of what agents need. Leave it be.

**E. Cloud-side agents instead of local ones.** Run the agent inside
Basecamp's infrastructure and skip the connectivity question entirely. Out of
scope here — the local model is the point of this experiment (your machine,
your credentials, your repos, your tools) — but note the Agent personable and
the addressed-event model are exactly what a hosted agent would need too.
Nothing in this design forecloses it; the Channel is just one consumer shape.

---

## Suggested staging

1. **`Agent` personable + agent token.** Mentionable, reachable, subscribable,
   assignable, badge in UI, excluded from billing, authenticated API access.
   Immediately removes the fake-account hack even with webhooks still in use.
2. **The inbox** (alternative B as a milestone): durable per-agent event queue
   with a cursor, consumable via API. Conversation and chat mentions start
   working here; the connector sheds the funnel, webhooks, corroboration, and
   teardown in one stroke.
3. **The stream**: live delivery over a connection + presence lease. Latency
   drops to real-time; the UI can show agent availability.
4. **Container watches**: structural events for card tables, columns, and
   todolists. Boards become automation surfaces.
5. **Directive policy UI**: operators, allowed directors, per-agent settings
   in Adminland.

Each stage is independently useful, and the connector in this repo can adopt
them incrementally — it already has the right split (trusted-event stream in,
API actions out), so it degrades gracefully into a thin client of the Channel
and eventually into nothing but the `basecamp` CLI and a skill.

---

## Open questions

- **Retention and overflow.** How long does an offline agent's inbox retain
  events? What does the UI show when an agent has a large backlog?
- **Multiple runtimes per agent.** Two laptops connect as the same agent —
  compete for events, or duplicate delivery? (Leases suggest single-active
  with takeover.)
- **Directive policy granularity.** Per-agent list of people, or roles
  ("anyone on the project")? Does an unauthorized mention notify the operator?
- **Agent-to-agent.** May one agent mention or assign another? (Loop
  prevention needs more thought than the human↔agent case.)
- **Client visibility.** Should agents ever be visible to client users, and
  can clients direct them?
- **Rate and abuse limits.** An agent is a machine author — what posting and
  API limits apply, and how do they surface?
