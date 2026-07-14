# Built-in agent support in Basecamp

## Purpose

The connector in this repo proved the idea: you @mention an agent user in
Basecamp, a Claude agent on your machine picks it up, works with full Basecamp
context, and replies in place. It works — but every piece of it is a
workaround for something Basecamp doesn't provide. This document proposes what
Basecamp (BC5) should build so the approach is native, with all of today's
limitations removed. High-level only; no implementation detail beyond what's
needed to show each idea is grounded in the current codebase.

The two recommendations:

1. **An `Agent` personable type** — a first-class kind of person for AI agents.
2. **The Agent Channel** — a dedicated delivery mechanism for agents: a durable
   per-agent inbox plus a live Action Cable stream, replacing webhooks for this
   use case entirely.

---

## What the connector has to work around today

Every mechanism in the connector maps to a gap in Basecamp:

| # | Limitation | Root cause in bc3 |
|---|-----------|-------------------|
| 1 | **Per-project watch lists** — one webhook registered per project | Webhooks are strictly per-bucket; no account-level subscription exists |
| 2 | **No chat** — Campfire can't drive the agent | Chat events are hard-excluded from webhooks ("will have its own API" — it never came) |
| 3 | **Agent is a full human user account** — login, Launchpad identity, seat | The existing bot type (`Integration`) can't be mentioned, can't receive notifications, can't read anything, can't use OAuth |
| 4 | **Public inbound endpoint** — Tailscale Funnel publishes the laptop | Webhooks push to a URL; nothing lets a consumer connect *out* and receive events |
| 5 | **Forgeable deliveries** — every event re-fetched and corroborated | Webhook deliveries carry no signature |
| 6 | **Manual lifecycle, orphan risk** — teardown required; SIGKILL leaves stale webhooks and a live funnel; silent deactivation after 10 failures | Webhooks are durable registrations with no lease, TTL, or self-expiry |
| 7 | **No conversation** — a plain reply to the agent's question never reaches it | Mentions already auto-subscribe the mentionee, and subscribers are notified of every comment — but no machine consumer can read a person's notification stream |
| 8 | **Client-side filtering of a project firehose** — operator and mention checks happen on the laptop | Webhooks filter by recording type only, not addressee or author |
| 9 | **No structural events** — card-moved-to-column / todo-added means client-side diffing | Those events exist internally but aren't subscribable per-container |
| 10 | **Two id spaces joined by email** — account Person id vs. global identity id | No stable common key surfaced in both places |
| 11 | **Trust policy lives in the client** — "only the operator may direct the agent" is invisible to Basecamp | Basecamp has no concept of an agent, so no concept of who may direct one |

## Design principles

- **Dedicated, not repurposed.** Webhooks are a generic integration surface
  with the wrong shape for this. Agents get a purpose-built mechanism.
- **Person-centric addressing.** The unit of delivery is "something addressed
  to this agent" — mention, thread reply, assignment, watched-container change
  — across the whole account. The server filters; the agent never sees a
  firehose and never configures projects.
- **The agent connects out; Basecamp never calls in.** No public endpoint, no
  funnel, no forgery surface.
- **Auto-cleaning by construction.** Nothing durable is registered. Live
  delivery lasts exactly as long as the connection (plus a short lease);
  a dead process leaves nothing to tear down.
- **Reuse the social model.** Mentions, subscriptions, assignments, and
  notifications already encode "who should hear about this." Agents plug into
  that machinery as people.
- **Trust is Basecamp's job.** Who may direct an agent is account
  configuration, enforced server-side.

---

## Recommendation 1: the `Agent` personable type

Basecamp already has the pattern: `Person` delegates to a personable (`User`,
`Client`, `Outsider`, `Integration`, `Tombstone`, `DummyUser`). Add **`Agent`**.

What an Agent person **is**:

- **Mentionable** — in mention candidates and people pickers everywhere,
  *including rich-text chat lines* (chat already permits mention attachments;
  the only blocker is that non-User people are excluded from candidates).
- **Reachable and subscribable** — a valid notification recipient and thread
  subscriber. This is what powers conversation.
- **Assignable** — a valid assignee for todos and cards, and a valid
  participant in pings and Campfires.
- **Attributable** — its actions are authored by it, with a bot-style avatar
  and an "agent" badge so nobody mistakes it for a human.
- **Owned** — it belongs to its operator(s); admins manage agents in Adminland.

What it **is not**: not a seat (excluded from billing and user limits, as
`Integration` people are); not a Launchpad identity (no login — it
authenticates with an **agent token**, the `access_key`-on-Person precedent,
giving it exactly one id: its Person id); not omnipotent (normal project
access rules apply, and its API surface can be scoped tighter than a user's).

**Trust model, in product.** Each agent carries a directive policy: who may
direct it (defaulting to its operator). Mentions, assignments, and thread
replies from anyone else are filtered — or flagged — server-side, before
delivery. Today's client-side operator filter moves into Basecamp, visible
and auditable.

**Why not extend `Integration`?** It is deliberately a write-only chat bot —
unmentionable, unreachable, no reads, synchronous public `command_url` — and
its admin-created, account-wide shape doesn't match "my personal coding
agent." A fresh personable type is cleaner and leaves Integration alone.

---

## Recommendation 2: the Agent Channel

Two halves over one mechanism: a **durable inbox** (nothing is missed while
offline) and a **live stream over Action Cable** (real-time wake-up, ack, and
presence). Replies and actions go through the existing REST API as the agent —
the experiment already proved the API covers everything needed.

### What gets delivered

Everything is addressed to the agent; the server filters:

1. **Mentions** — any recording in any project the agent can access,
   *including chat lines and pings*. Chat's webhook exclusion is irrelevant:
   this rides the mention/notification path, and volume is inherently bounded.
2. **Thread replies without re-mention.** Basecamp already does the hard part:
   a mention auto-subscribes the mentionee, and every new comment notifies
   subscribers. Once you mention the agent (or it comments), it's in the
   conversation — your plain reply reaches it like it would reach a human.
   Ping rooms give the same for chat.
3. **Assignments** — with who assigned.
4. **Container watches** — the agent watches a card table, column, or
   todolist and receives structural events: card moved in/out, todo added or
   completed. Boards become automation surfaces ("anything landing in *Ready
   for agent* gets worked"), with no client-side diffing. No new mechanism: a
   watch is simply the agent subscribed to the container, and the relay logic
   resolves interested agents from the event.
5. **Directive gating** — events from people outside the agent's directive
   policy never get delivered.

Each event is a **trigger plus pointer** — enough to know what happened and
where, with URLs to pull full context from the API. That division of labor is
proven by the connector and keeps events small.

### Why Action Cable

The infrastructure for authenticated per-user streams already exists, and the
protocol is plain JSON over a WebSocket — nothing browser-specific. A headless
Ruby client (the connector's successor, ultimately the `basecamp` CLI) opens
the socket with its agent token, subscribes to its agent channel, and gets
fully bidirectional messaging: dispatches flow down; acks, cursor advances,
and lease renewals flow up as channel actions. No new transport layer to
build or operate.

One property to design around: Cable pub/sub is fire-and-forget — a broadcast
during a disconnect is gone. That's exactly why the inbox is durable: the
stream is the wake-up and the ack path; on every (re)connect the client
catches up from its cursor. The channel only ever has to hint that something
new exists.

### Why it's trustworthy

- Deliveries arrive over a connection the agent opened and authenticated —
  no public endpoint, nothing to forge, no corroboration re-fetch needed.
- Directive policy is enforced server-side.
- Loop prevention is structural: an actor's own actions never generate events
  back to itself (the notification machinery already excludes the creator).

### Why it auto-cleans

- **Live delivery is the connection.** Process dies → connection drops →
  nothing is listening, nothing public exists, nothing to delete. The inbox
  accumulates within retention, so a restart resumes cleanly.
- **Presence is a lease.** While connected (renewing a short TTL), the agent
  shows *active* — people can see it's listening before they mention it (a
  real papercut today: you write to an agent whose laptop is asleep). Lease
  lapses → *offline*; mentioning an offline agent can warn you.
- **Watches are just subscriptions, not endpoints** — visible and revocable on
  the container, harmless if the process is gone.

Contrast with today: delete N webhooks and reset a public funnel on every
exit, and hope you're never SIGKILLed.

---

## Suggested domain model

The spine is untouched: **`Event` stays the single source of truth.** Every
trigger that matters (mention, comment, assignment, card move, todo added)
already produces an `Event`, and `Event::RelayJob` already fans each one out
to the timeline, webhooks, readers, and notifications. Agent delivery is one
more relay step — not a parallel event system.

New concepts, all small:

- **`Agent`** — the new personable, alongside `User`, `Client`, `Integration`,
  etc. Carries the agent's profile (name, avatar, description), its
  **agent token** for API and Cable authentication, and its **directive
  policy** — who may direct it (default: its operators), checked at relay time
  against the event's creator. Joins the personable scopes deliberately:
  mentionable, reachable, subscribable, assignable; excluded from billing and
  people-management abilities.

- **`Agent::Dispatch`** — the inbox row; the machine-facing sibling of
  `Notification`. Essentially *(agent person, event, reason, position,
  acked-at)*. `reason` is the addressing that webhooks lack: *mentioned*,
  *thread reply*, *assigned*, *watch*, *ping line*. Created by the new
  `relay_to_agents` step in `Event::RelayJob`, which computes the addressed
  agents (mentionees, thread subscribers, assignees, container subscribers —
  intersected with each agent's directive policy). The row is cheap metadata; the JSON the client
  sees is rendered from the event at read time (the same pattern webhook
  deliveries use), so payloads aren't persisted twice. Dispatches expire after
  a retention window.

  Why not reuse `Notification`? It's 80% right (event, addressed to a person,
  because mentioned or subscribed) but UI-shaped — bundling, read/unread, the
  6-hour chat hold — and it has no concept of container watches. A parallel,
  deliberately dumber model shares the upstream recipient logic and leaves
  `Notification` human-facing.

- **`AgentChannel`** (Action Cable) — the agent's stream. Authenticated by
  agent token at connection; broadcasts a wake-up when new dispatches land.
  Client-to-server actions: acknowledge / advance cursor, renew lease. A
  matching REST endpoint lists dispatches from a cursor for catch-up — the
  same rows, so the stream and the inbox can never disagree.

The flow end to end: recording saved → `Event` created → `Event::RelayJob`
runs `relay_to_agents` → `Agent::Dispatch` rows for each addressed agent →
`AgentChannel` broadcast wakes the connected runtime → it reads from its
cursor, pulls context via the REST API, works, replies as the agent → its own
reply excludes itself from the next round of recipients.

---

## How the limitations dissolve

| Today | With Agent + Channel |
|-------|----------------------|
| `--project` watch lists, one webhook per project | Account-wide, addressed delivery; zero per-project configuration |
| No chat | Chat mentions and ping rooms delivered like everything else |
| Fake human account with a seat and a login | `Agent` personable: no seat, no login, one token, one id |
| Tailscale Funnel / public endpoint | Agent connects out; no inbound surface at all |
| Unsigned deliveries + corroboration re-fetch | Authenticated connection; deliveries authentic by construction |
| Register/teardown lifecycle, orphans | Connection + lease; nothing durable, nothing to clean |
| Re-mention on every reply | Subscription-based conversation, like a human |
| Client-side operator filtering | Server-side directive policy, visible in product |
| Client-side diffing for boards/lists | First-class container watches with structural events |
| Person id vs. identity id, joined by email | One id: the agent's Person id |

---

## Suggested staging

1. **`Agent` personable + agent token** — mentionable, reachable, assignable,
   badged, unbilled, API-authenticated. Removes the fake-account hack even
   with webhooks still in use.
2. **The inbox** — `Agent::Dispatch` + the relay step + the cursor REST
   endpoint. Conversation and chat mentions start working; the connector sheds
   the funnel, webhooks, corroboration, and teardown in one stroke.
3. **The stream** — `AgentChannel` + presence lease. Real-time latency; the UI
   shows agent availability.
4. **Container watches** — structural events for card tables, columns,
   todolists.
5. **Directive policy UI** — operators, allowed directors, Adminland settings.

Each stage is independently useful, and the connector adopts them
incrementally — it already has the right split (trusted-event stream in, API
actions out), so it degrades gracefully into a thin client of the Channel and
eventually into nothing but the `basecamp` CLI and a skill.

## Open questions

- **Retention and overflow** — how long does an offline agent's inbox retain
  dispatches, and what does the UI show for a large backlog?
- **Multiple runtimes per agent** — two laptops connect as the same agent:
  compete or duplicate? (Leases suggest single-active with takeover.)
- **Directive policy granularity** — a list of people, or roles ("anyone on
  the project")? Does an unauthorized mention notify the operator?
- **Agent-to-agent** — may one agent mention or assign another? Loop
  prevention needs more thought than the human↔agent case.
- **Client visibility** — should client users see or direct agents?
- **Rate and abuse limits** — what posting and API limits apply to a machine
  author, and how do they surface?
