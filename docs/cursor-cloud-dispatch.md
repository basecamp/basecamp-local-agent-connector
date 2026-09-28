# Dispatching a mention to a Cursor cloud agent

**Experimental, and stopped.** This is a spike, not a supported path. Work on
it stopped on 28 Sep 2026: dispatching to Cursor from the connector is not the
direction. A mention of a hosted agent should start Cursor from inside bc3,
which continues on the card
[bc3: a mention of a hosted agent triggers Cursor from inside bc3](https://app.basecamp.com/2914079/buckets/48699913/card_tables/cards/10346589921).
What stays here is the cheapest way to learn how Cursor behaves: one live run
is still owed, and [the live run](#the-live-run) says exactly how to make it.

The connector's whole job is to notice that someone mentioned an agent and say
so on STDOUT. What reads that line is up to you. `bin/connect` was built for a
local agent on this machine; `bin/dispatch-cursor` is the other option — hand
the work to a [Cursor cloud agent](https://cursor.com/docs/cloud-agent/api/overview)
with no repository, give it the hosted Basecamp MCP server as its hands, and
let it reply on the card itself.

```
bin/connect @marie --project "Bring your agents to Basecamp" \
  | tee >(bin/dispatch-cursor @marie)
```

`tee` rather than a pipe, because the local watcher should keep getting the
same stream. Nothing about the connector changes.

The agent name is repeated for the same reason `bin/connect` asks for it:
anything this process says on a card has to come from the account the mention
named, and the `basecamp` CLI's default profile is the operator.

## What it sends

One `POST https://api.cursor.com/v1/agents` per verified mention:

```json
{
  "prompt": { "text": "… the card URL, the comment, and the job …" },
  "name": "Re: PoC test card (safe to trash)",
  "agentId": "bc-db5d738e-cd2a-3b32-5dc5-698d611fc27f",
  "mcpServers": [
    {
      "name": "basecamp",
      "type": "http",
      "url": "https://mcp.basecamp.com/mcp",
      "headers": { "Authorization": "Bearer $BASECAMP_MCP_TOKEN" }
    }
  ]
}
```

No `repos` key at all is what makes it a no-repo agent — there is no code in
this job, only Basecamp. Cursor's API reference says to "omit both `repos` and
`env` to start a no-repo agent"; an empty list is accepted by the SDK too, but
omission is the documented shape, so that is what goes on the wire. The inline `mcpServers` entry is the hands: Cursor proxies those
headers to the MCP server from its backend, so the token never enters the
agent's VM.

`agentId` is derived from the Basecamp `event_id` (SHA-256, formatted as the
`bc-<uuid>` shape Cursor requires). Re-POSTing the same id is refused with
`409 agent_id_conflict`, so a replayed line cannot start the same work twice —
which matters, because re-arming a watcher over a stream replays events and
in-process bookkeeping would not survive a restart anyway. That 409 is read as
"already dispatched" and skipped, not as a failure; nothing one event does
stops the next one being dispatched.

To see the exact body for an event without sending anything:

```bash
bin/dispatch-cursor --print < test/fixtures/cursor_mention_event.ndjson
```

The equivalent call by hand, with both secrets left in the environment:

```bash
curl -sS -X POST https://api.cursor.com/v1/agents \
  -H "Authorization: Bearer $CURSOR_API_KEY" \
  -H "Content-Type: application/json" \
  -d "$(bin/dispatch-cursor --print < event.ndjson \
        | sed "s|\$BASECAMP_MCP_TOKEN|$BASECAMP_MCP_TOKEN|")"
```

## Which events

`trigger.mentioned` and nothing else. That flag is the Verifier's verdict,
settled against the re-fetched recording and the agent's Person id before the
event was emitted; re-deriving it here from `recording.content` would be a
second, weaker answer to a question already answered.

Beyond that, only a card or a comment **on a card**. A comment on a message,
a document or a to-do is type `Comment` too, and the prompt written here
assumes there is a card to read and to reply on — so those stay with the local
watcher rather than reaching a cloud agent pointed at the wrong URL.

## Learning the outcome

`POST /v1/agents` returns `{ agent, run }` — the create carries the first run.
The dispatcher then polls `GET /v1/agents/{id}/runs/{runId}` every 5s until
`status` leaves `CREATING`/`RUNNING`, capped at 10 minutes.

Each watch gets its own thread. The POST is the only thing the reading loop
waits for, because a run can take ten minutes and a reader that stops reading
for ten minutes fills the pipe it is reading from — which blocks the connector
inside its own `emit`. Reading stops when the stream closes, and only then does
the dispatcher wait for the watches still in flight.

Polling rather than webhooks or SSE: v1 webhooks are "coming soon" (v0 has
them, but v0 has no inline MCP and requires a repo), and a receiver would need
a public URL that only the connector's tunnel provides. The SSE stream at
`…/runs/{runId}/stream` works and gives live tool-call visibility, but it holds
a connection open per event and tells the card nothing it won't learn anyway.

## Who replies

The agent does, on the card, through `basecamp_comments_write` /
`create_comment`. The dispatcher speaks only when the run ends anything other
than `FINISHED` — `ERROR`, `EXPIRED`, `CANCELLED`, a poll that timed out, or a
create that never got through to Cursor at all. It then posts one line on the
card as the agent — the `basecamp` CLI pinned to the profile named on the
command line — saying how the run ended and that the list is worth checking.

That way round because it is one identity end to end — the MCP token is the
agent's, so the to-dos and the reply come from the same account that was
mentioned — and because the agent knows what it actually did, while the
dispatcher has only `run.result`, a prose summary it would be relaying as
fact. The fallback exists because a card that gets mentioned and then goes
silent is worse than a duplicate comment.

## Getting the MCP token: the browser path

The hosted MCP server accepts only tokens audienced to it (RFC 8707), and bc3
mints those through `authorization_code` + PKCE alone: a dynamically
registered client may hold no other grant, and a `basecamp` CLI token is the
right class and the wrong audience. So one person signs in once, in a browser,
**as the agent**, and the connector keeps the refresh token that comes back.

```bash
bin/mcp-authorize @marie
```

registers a public loopback client the first time (RFC 7591), prints an
authorize URL asking for `full mcp offline_access` with
`resource=https://mcp.basecamp.com/mcp`, and waits on
`http://127.0.0.1:8765/callback`. Open the URL in a browser **signed in to
Basecamp as the agent** — a private window keeps the operator's own session
out of it, and a token minted in the operator's session would make the
operator, not the agent, the one doing the work. Approve, and it stores the
refresh token in `~/.config/basecamp-agent-connector/mcp/<agent>.json`, mode
0600, outside any repository.

From then on, every token is a refresh with no browser:

```bash
BASECAMP_MCP_TOKEN="$(bin/mcp-token @marie)"
```

`bin/mcp-token` rotates the stored refresh token and refuses to print to a
terminal. `BASECAMP_MCP_URL` and `BASECAMP_AUTH_URL` point both scripts, and
`bin/dispatch-cursor`, at a beta instead
(`https://betaN-mcp.3.bc4-beta.com/mcp`, `https://betaN.3.bc4-beta.com`).

## The live run

**Pending: the Cursor service-account key.** Nothing below has run live yet.

The key goes in `CURSOR_API_KEY` in the dispatcher's own environment, read
from 1Password at the moment of the run and nowhere else — never a file, a
card, a commit or this doc. It must be a service-account key (Cursor dashboard
› Settings › API Keys › Service Accounts) or a user key, not repository-scoped,
on a team with no-repo agents enabled. The team key issued on 22 Sep is the
wrong kind: see the gates below.

With the key in 1Password and the browser step done once, the run is one
command. Start it, then mention the agent on a card in the project with three
to-dos:

```bash
CURSOR_API_KEY="$(op read 'op://Development/<service-account key item>/credential')" \
BASECAMP_MCP_TOKEN="$(bin/mcp-token @marie)" \
  bash -c 'bin/connect @marie --project "Bring your agents to Basecamp" | tee >(bin/dispatch-cursor @marie)'
```

The MCP token is minted when the command starts and is good for its access
token lifetime, so make the mention within a few minutes of starting it.

The dispatcher logs the create, polls the run, and when it ends logs one line
with the run's status, duration and token usage from
`GET /v1/agents/{id}/usage?runId=…` (or why usage was unavailable — it is early
access and answers `403 feature_unavailable` until enabled). That line is what
goes in the table below.

| | Result |
|---|---|
| Account check (`GET /v1/me`) | pending |
| Agent created, no repos | pending |
| First MCP tool call | pending |
| Three to-dos created, as the agent | pending |
| Comment back on the card, as the agent | pending |
| Duration | pending |
| Tokens (input / output / cache write / cache read) | pending |
| Cost | pending |

## What we have learned so far

Tested against the real endpoints, 22–28 Sep 2026.

- **The MCP 503 was ours.** `https://mcp.basecamp.com/mcp` answered every
  `bc_at_` token, real or garbage, with `503 Authorization upstream
  unavailable; retry` from 22 to at least 23 Sep. The cause was bc3's OAuth
  abuse tracker: every MCP user's token exchange leaves the MCP server
  through one egress IP, a few users with stale tokens tripped the
  `invalid_grant` threshold, and the tracker then 429ed every exchange for
  everyone. Fixed in
  [basecamp/bc3#13466](https://github.com/basecamp/bc3/pull/13466) (merged
  24 Sep): a confidential client that proved its secret is no longer charged
  for its token-exchange failures.
- **Retested 28 Sep: the 503 is gone.** A CLI `bc_at_` token and a garbage
  one now both get `401 invalid_token` with a `WWW-Authenticate` challenge,
  and no token gets the plain `401`. That is the exchange working and
  refusing a token not audienced to the MCP server — which is why the
  browser path above is the way in.
- **The browser path works up to the sign-in.** A loopback client
  registered, and its authorize URL passes bc3's pre-authorization checks
  and redirects to sign-in. The approval itself needs a person signed in as
  the agent, so the MCP token is pending that one step.
- **Cursor's key types.** A key from the dashboard's *Team API Keys* tab is
  for the Admin API only; every Cloud Agents endpoint, `GET /v1/me`
  included, answers it with `401` and a message saying so. Found on 23 Sep
  with the first key issued for this spike, so `bin/dispatch-cursor` never
  got past the create — the run ended `UNDISPATCHED` and the fallback
  comment landed on the card as the agent, the failure path doing its job.
  Cost so far: $0.
- **No-repo agents** must be enabled for the team, and a
  repository-scoped key cannot create one. Omit `repos` (and `env`).
- **Inline MCP headers are proxied from Cursor's backend**, so the MCP token
  never enters the agent's VM — but they are static for the run, so the
  token has to outlive it. A refresh right before the create covers a
  10-minute run.
- **Cursor's inline OAuth (`auth`)** is per user and reuses a prior
  authorization on cursor.com; it is not a way for an unattended runner to
  hold an agent's identity.

## Why the connector version stops here

The connector can only dispatch from a machine someone keeps running, and the
token it hands Cursor is the agent's own, minted once by a person in a
browser. Inside bc3 neither is true: the mention is already an event there,
and bc3 can mint the MCP-audienced token itself, riding the mentioner's
delegation to the agent so that the agent stays the performer through
TokenDelegation. That is the bc3 card linked at the top. This branch stays
unmerged, as the record of what the spike learned; it owes one live run.
