# basecamp-local-agent-connector

Manage local Claude Code agents from Basecamp. Write `@agent do X` in a Basecamp
comment, message, or card, and a background agent on **your** machine picks it
up, gathers context from Basecamp, and acts on it — then replies where you wrote
the trigger.

Basecamp is a great place to *capture context*: a comment lives inside a card,
inside a project, with a creator and a thread. Instead of re-typing all that
into Claude, you write where the work already lives, and the agent pulls the
surrounding context from Basecamp.

---

## How it works

```
  You, in Basecamp                 Your machine
  ────────────────                 ─────────────────────────────────────────
  comment "@agent fix         ┌──>  bin/connect (Ruby)
  the calendar bug"  ──webhook┘       • WEBrick server on a secret local path
                                      • exposed via Tailscale Funnel (public URL)
                                      • filters: self-authored + trigger match
                                      • verifies the event against Basecamp API
                                      • prints trusted events to STDOUT (NDJSON)
                                              │
                                              ▼
                          /basecamp-connect skill (Claude Code)
                                      • resolves the local repo from the project
                                      • gathers context via the `basecamp` CLI
                                      • dispatches a background agent in that repo
                                      • replies on the card as the linked identity
```

Two halves:

1. **`bin/connect`** — the bridge. Exposes a local webhook endpoint to the
   internet, registers it as a Basecamp webhook (one per watched project),
   filters and verifies deliveries, and emits only trusted events to STDOUT.
2. **`/basecamp-connect` skill** — the driver. Runs `bin/connect`, watches its STDOUT,
   and turns each trusted event into a background agent task with full Basecamp
   context.

See [`docs/spec.md`](docs/spec.md) for the complete design.

---

## Install

### 1. The skill

```bash
npx skills add jorgemanrubia/basecamp-local-agent-connector
```

This installs the `/basecamp-connect` skill content into your agent's skills directory
(follows the [Agent Skills](https://agentskills.io/specification) spec).

### 2. The runtime

The skill drives `bin/connect`, so you also need this repo cloned and set up:

```bash
git clone https://github.com/jorgemanrubia/basecamp-local-agent-connector
cd basecamp-local-agent-connector
bin/setup          # bundle install + prerequisite checks
```

Running Claude Code from the clone auto-discovers the skill (via the bundled
`.claude/skills` symlink), so step 1 is optional if you work from the clone.

### Prerequisites

- **[`basecamp` CLI](https://github.com/basecamp)** — installed and
  authenticated (`basecamp auth login`). The connector resolves your linked
  identity and posts replies through it.
- **[Tailscale](https://tailscale.com)** with **Funnel enabled** for your
  tailnet. Funnel (not Serve) is required because Basecamp's servers must reach
  the endpoint over the public internet.
- **Ruby 3.4+**.

---

## Usage

From the skill:

```
/basecamp-connect @agent --project "BC5 Calendar"               # one project
/basecamp-connect @agent --project "BC5 Calendar" --project HEY  # several
```

Or run the bridge directly (it just prints trusted events as NDJSON):

```bash
bin/connect @agent --project "BC5 Calendar"
bin/connect @agent --project "BC5 Calendar" --project "HEY Triage"
bin/connect @agent --project Queenbee --types Comment,Message --port 4567
```

`--project` is **required** — Basecamp webhooks are per-project (there is no
account-level webhook in the API). Pass a project **name, URL, or ID**; the
`basecamp` CLI resolves it. Repeat `--project` to watch several.

| Flag | Meaning | Default |
|------|---------|---------|
| `<trigger>` | The token to watch for (required) | — |
| `--project` | Project name/URL/ID, **required**, repeatable | — |
| `--types` | Comma-separated Basecamp event types | `Comment,Message,Kanban::Card` |
| `--port` | Local server port | an unused high port |

Press **Ctrl-C** to stop: every registered webhook is deleted and the Tailscale
Funnel is reset. Nothing is left running.

---

## Trust model

A webhook payload is attacker-influenceable text flowing into an agent that can
run commands. `bin/connect` only emits an event when **all** of these hold:

1. **Self-authored** — the event's creator is the *linked Basecamp identity*
   (by default, whoever the `basecamp` CLI is authenticated as). A third party
   who can comment in the project cannot inject instructions into your agent.
2. **Trigger-matched** — the trigger token (e.g. `@agent`) appears in the
   content, matched on a word boundary, case-insensitive (so `@agent` matches
   but `@agentsmith` does not).
3. **Corroborated** — the recording is re-fetched from the Basecamp API and
   confirmed (it exists, with the claimed creator). The Funnel URL is public and
   Basecamp sends no signature, so a forged POST is possible — but it can't
   survive API corroboration. A random secret URL path is a cheap first gate.

The content acted on is the **authoritative copy fetched from Basecamp**, never
the raw POST body.

---

## Configuration

- **Linked identity** — the Basecamp user used both as the self-authored filter
  target and as the reply identity. Defaults to the `basecamp` CLI's
  authenticated account.
- **Project → repo mapping** — [`config/project_repos.toml`](config/project_repos.toml)
  maps Basecamp project-name tokens to local repo paths. The `/basecamp-connect` skill
  uses it to decide where to run each agent; if no mapping matches, it asks you.

---

## Development

```bash
bin/setup                 # or: bundle install
bundle exec rake test     # minitest suite
bundle exec rubocop       # 37signals house style
```

The code is a small [Zeitwerk](https://github.com/fxn/zeitwerk)-autoloaded gem
under `lib/basecamp_agent_connector/`. External commands (`basecamp`,
`tailscale`) are reached through an injectable command runner, so the test suite
stubs the subprocess boundary rather than mocking the gem's own classes.

### Layout

```
bin/connect                          # executable shim → CLI.start
lib/basecamp_agent_connector/        # one class per concern
  command_runner  basecamp_cli  identity  projects
  tunnel  webhooks  server  event  verifier  pipeline  emitter  cli
skills/basecamp-connect/SKILL.md     # the /basecamp-connect skill
config/project_repos.toml            # project → repo mapping
test/                                # minitest, mirrors lib/
docs/spec.md                         # full design
```

## License

MIT.
