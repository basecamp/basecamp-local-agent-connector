# Dispatching a mention to a Cursor cloud agent

**Experimental.** This is a spike, not a supported path. It does not work
end to end today, and the reason it does not is written down at the bottom.

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
  "repos": [],
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

`"repos": []` is what makes it a no-repo agent — there is no code in this job,
only Basecamp. The inline `mcpServers` entry is the hands: Cursor proxies those
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

## What is missing

**A bearer token for `https://mcp.basecamp.com/mcp` that an unattended
process can hold.** Everything else here works; this does not, and it is a
Basecamp-side gap rather than a Cursor one.

- The hosted MCP server accepts only `bc_at_` tokens, and validates them by
  exchanging them (RFC 8693) for an API token. The exchange rejects a subject
  token that is not audienced to the MCP server's own OAuth client.
- An agent's `bc_at_` token from the `basecamp` CLI is the right class and the
  wrong audience.
- Minting a correctly-audienced one means `authorization_code` + PKCE — a
  browser, once, per agent identity. Dynamic client registration works, but
  bc3 answers a DCR request asking for anything else with
  `invalid_client_metadata: Dynamically registered clients only support the
  authorization_code and refresh_token grants`, so `client_credentials` and
  `token-exchange` are closed to a self-registered client.
- Cursor's inline OAuth (`auth`) is not a way round it: it is per-user and
  needs a prior authorization on cursor.com, which is the same browser step
  moved somewhere less convenient.

So an unattended runner needs either a first-party OAuth client (issued by
37signals, with `client_credentials` or token-exchange enabled) or a one-time
human authorization whose refresh token the runner then keeps.

Two Cursor-side gates to check before assuming this works on an account:
no-repo agents must be enabled for the team (a repository-scoped API key cannot
create one), and `GET /v1/agents/{id}/usage` answers `403 feature_unavailable`
until early access is turned on.
