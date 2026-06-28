# basecamp-local-agent-connector

Manage local Claude Code agents from Basecamp. Write `@agent do X` in a Basecamp
comment, message, or card, and a background agent on your machine picks it up,
gathers context from Basecamp, and acts on it.

The bridge has two halves:

1. **`bin/connect`** — a Ruby process that exposes a local webhook server to the
   internet (via Tailscale Funnel), registers it as a Basecamp webhook, and
   prints **trusted** events to STDOUT.
2. **`/basecamp` skill** — a Claude Code skill that runs `bin/connect`, watches
   its STDOUT, and dispatches each trusted event to a background agent with full
   Basecamp context.

See [`docs/spec.md`](docs/spec.md) for the full design.

## Trust model

A webhook payload is attacker-influenceable text flowing into an agent that can
run commands, so `bin/connect` only emits an event when **all** hold:

- **Self-authored** — the event's creator is the linked Basecamp identity
  (default: whoever the `basecamp` CLI is authed as).
- **Trigger-matched** — the trigger token (e.g. `@agent`) appears in the
  content, matched word-boundary and case-insensitive.
- **Corroborated** — the recording is re-fetched from the Basecamp API and
  confirmed (existence + creator). The public funnel URL means anyone could POST
  a forged payload; only Basecamp-corroborated events survive. A random secret
  URL path is a cheap first gate.

## Usage

```bash
bin/connect @agent                          # watch all accessible projects
bin/connect @agent --project "BC5 Calendar" # narrow to one or more projects
bin/connect @agent --types Comment,Message --port 4567
```

On exit (Ctrl-C), every registered webhook is deleted and the funnel is reset.

Prerequisites:

- The [`basecamp` CLI](https://github.com/basecamp), authenticated.
- Tailscale with Funnel enabled for the tailnet.

## Development

```bash
bundle install
bin/rake test     # minitest suite
rubocop           # 37signals house style
```

The code is a small Zeitwerk-autoloaded gem under `lib/basecamp_agent_connector/`.
External commands (`basecamp`, `tailscale`) are reached through an injectable
command runner, so the suite stubs the subprocess boundary rather than mocking
the gem's own classes.
