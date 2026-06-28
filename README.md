# basecamp-local-agent-connector

Drive local Claude Code agents from Basecamp. **@mention an agent user** (e.g.
`@Clawdito fix the calendar bug`) in any Basecamp comment, message, or card — and
a Claude agent on **your** machine picks it up, gathers the surrounding context
from Basecamp, does the work in the right repo, and **replies as that agent
user**, right where you asked.

Basecamp is already where the work and its context live — a comment sits inside a
card, inside a project, with a thread and a creator. Instead of copy-pasting all
that into a terminal, you write where the work is and let the agent pull the
context it needs.

---

## For the end user

### What it feels like

1. In Basecamp, you comment on a card: **“@Clawdito the date picker is off by one — please fix.”**
2. On your laptop, the agent wakes up, reads the card and its thread, figures out
   which repo this is, and starts working.
3. A few minutes later, **Clawdito replies on the same card** with what it did
   (and, ideally, a PR link). If it hit a wall, it replies with the error and
   @mentions you.

You never leave Basecamp. The agent runs locally, as you, with your tools.

### The one-time setup

You need three things in place:

1. **The skill** — install it into Claude Code:

   ```bash
   npx skills add jorgemanrubia/basecamp-local-agent-connector
   ```

   (Or just run Claude Code from a clone of this repo — the skill is
   auto-discovered via `.claude/skills`.)

2. **The runtime** — clone the repo and install dependencies:

   ```bash
   git clone https://github.com/jorgemanrubia/basecamp-local-agent-connector
   cd basecamp-local-agent-connector
   bin/setup        # bundle install + checks for the `basecamp` and `tailscale` CLIs
   ```

   You also need [Tailscale](https://tailscale.com) with **Funnel enabled** for
   your tailnet (Basecamp has to reach your machine over the public internet) and
   Ruby 3.4+.

3. **An agent user + its local profile.** The agent is a *real Basecamp user*
   (e.g. a bot account named “Clawdito”) that you can @mention. The connector
   talks to Basecamp through the [`basecamp` CLI](https://github.com/basecamp),
   which supports named **profiles** — and the agent name you pass must match a
   local profile authenticated **as that agent user**:

   ```bash
   basecamp auth login --profile clawdito   # log in as the Clawdito account
   basecamp me --profile clawdito           # verify it's Clawdito, not you
   ```

   Your own login is the default profile (the **operator** — the only person
   allowed to trigger the agent). The agent and the operator **must be different
   Basecamp users**, otherwise the agent’s own replies would trigger it again.

### Using it

From Claude Code:

```
/basecamp-connect @Clawdito --project "BC5 Calendar"
```

That starts watching the named project(s). Now go to Basecamp and @mention
`@Clawdito` in a comment/message/card with what you want done. Each time you do,
the agent runs and replies.

- Watch several projects: repeat `--project`.
- `--project` takes a **name, URL, or ID** — the CLI resolves it.
- `--project` is **required**: Basecamp webhooks are per-project; there is no
  account-wide webhook.

### Stopping (and why it matters)

While running, the connector exposes a **public URL** (via Tailscale Funnel) and
registers a **real webhook** on each watched project. **Always stop it when
you’re done** — stopping deletes every webhook and closes the funnel
automatically. In Claude Code, ending the skill does this; from a terminal, press
**Ctrl-C**. Nothing is left running or exposed.

---

## How it works

```
  You, in Basecamp                  Your machine
  ────────────────                  ─────────────────────────────────────────
  "@Clawdito fix the      ┌───>   bin/connect  (the bridge, Ruby)
   calendar bug"   ──webhook┘        • WEBrick server on a secret local path
                                     • exposed publicly via Tailscale Funnel
                                     • filter: authored by operator + @mentions agent
                                     • re-fetches & verifies the event vs Basecamp API
                                     • prints trusted events to STDOUT (one JSON/line)
                                              │
                                              ▼
                          /basecamp-connect  (the driver, a Claude skill)
                                     • resolves the local repo from the project
                                     • gathers context via the `basecamp` CLI
                                     • dispatches a background Claude agent in that repo
                                     • replies on the card as the agent (--profile)
```

Two halves, deliberately separated:

1. **`bin/connect`** — the **bridge**. A small Ruby process: it opens the public
   endpoint, registers the webhooks, and does the *security-critical* filtering
   and verification. It emits only trusted events as NDJSON and touches nothing
   else.
2. **`/basecamp-connect`** — the **driver**. A Claude Code skill that runs the
   bridge, reads its output, turns each event into a background-agent task in the
   right repo, and posts the reply.

The bridge is dumb-and-safe; the driver is smart-and-contextual. You can run
`bin/connect` on its own to see exactly what would be dispatched.

---

## Trust & security model

A webhook payload is attacker-influenceable text that flows into an agent which
can run commands. `bin/connect` emits an event only when **all** of these hold:

1. **Authored by the operator.** The event creator must be *you* (the CLI default
   profile, or `--operator <profile>`), matched by email. A third party who can
   comment in the project cannot make your agent do anything.
2. **@mentions the agent.** `recording.content` must contain a real Basecamp
   mention of the agent user — a mention *attachment*
   (`application/vnd.basecamp.mention`) naming the agent, not just loose text
   that happens to contain the name.
3. **Corroborated by Basecamp.** The recording is re-fetched from the Basecamp
   API and confirmed (it exists, with the claimed creator). The funnel URL is
   public and Basecamp sends no signature, so a forged POST is possible — but it
   can’t survive API corroboration. A random secret URL path is a cheap first
   gate on top.

The content acted on is the **authoritative copy fetched from Basecamp**, never
the raw POST body.

**No reply loop.** Replies are posted *as the agent*, a different user than the
operator. Because the trust filter requires the *operator* to be the author, the
agent’s own replies can never re-trigger the connector. (`bin/connect` warns at
startup if the agent and operator resolve to the same Basecamp user.)

---

## Internal command: `bin/connect`

The bridge. Run it directly to watch a project and print trusted events; the
skill runs exactly this under the hood.

```bash
bin/connect @Clawdito --project "BC5 Calendar"
bin/connect @Clawdito --project "BC5 Calendar" --project "HEY Triage"
bin/connect @Clawdito --project Queenbee --operator jorge --port 4567
```

| Argument / flag | Meaning | Default |
|-----------------|---------|---------|
| `@AGENT` | Agent user / local `basecamp` profile to watch for and reply as. Leading `@` optional; lowercased to the profile name. **Required**, validated at startup. | — |
| `--project` | Basecamp project name, URL, or ID. **Required**, repeatable. | — |
| `--operator` | Profile whose user is allowed to trigger. | CLI default profile |
| `--types` | Comma-separated Basecamp event types to subscribe to. | `Comment,Message,Kanban::Card` |
| `--port` | Local port for the webhook server. | an unused high port |

**What it does, in order:**

1. **Resolve agent & operator.** Validates the agent name maps to a usable local
   profile (`basecamp me --profile <agent>`); if not, it aborts with
   `Run basecamp auth login --profile <agent>…`. Resolves the operator identity
   (refreshing an expired token once). Warns if agent == operator.
2. **Open the endpoint.** Starts a WEBrick server on `127.0.0.1:<port>` that only
   accepts `POST /hook/<random-secret>`; everything else is 404. One server + one
   funnel + one secret path serves every watched project.
3. **Expose it.** `tailscale funnel` publishes the server at a public
   `https://<host>.ts.net` URL.
4. **Register webhooks.** Creates one webhook per project (with retry on transient
   failures), recording their IDs for cleanup.
5. **Listen.** For each delivery: respond `200` immediately, then off the hot
   path — pre-filter (operator-authored + mentions agent + actionable kind),
   de-duplicate by event id, verify against the Basecamp API, and **print the
   trusted event as one line of NDJSON** to STDOUT. Dropped/diagnostic lines go
   to STDERR.

**Emitted event (STDOUT, one JSON object per line):**

```json
{"event_id":99001,"kind":"comment_created","created_at":"…",
 "creator":{"id":100,"name":"Jorge Manrubia","email_address":"jorge@…"},
 "recording":{"id":456,"type":"Comment","app_url":"…","url":"…",
   "content":"<p>… <bc-attachment content-type=\"application/vnd.basecamp.mention\">…Clawdito…</bc-attachment> fix X</p>",
   "parent":{…},"bucket":{"id":222,"name":"BC5 Calendar"}}}
```

**Teardown.** On `SIGINT`/`SIGTERM` it deletes **every** registered webhook
(best-effort, reporting any it couldn’t) and resets the funnel, then stops the
server. The funnel and webhooks live only for the lifetime of the process. If it
is ever `SIGKILL`ed, clean up manually:

```bash
basecamp webhooks list   --project "<project>"        # find leftovers
basecamp webhooks delete <id> --project "<project>"
tailscale funnel reset
```

### Useful `basecamp` CLI commands

```bash
basecamp me [--profile <name>]                         # who a profile is
basecamp webhooks list   --project "<project>" -j      # webhooks on a project
basecamp comment <recording-url> "…" --profile <agent> # post as the agent
```

---

## Configuration

- **Agent profile** — a local `basecamp` CLI profile authenticated as the agent
  user. The mention target *and* the reply identity (`basecamp comment …
  --profile <agent>`).
- **Operator** — the user allowed to trigger; defaults to the CLI default
  profile, override with `--operator <profile>`. Must differ from the agent.
- **Project → repo mapping** — [`config/project_repos.toml`](config/project_repos.toml)
  maps Basecamp project-name tokens to local repo paths. The skill uses it to
  decide where to run each agent; if nothing matches, it asks you.
- **Event types** — `--types` (default `Comment,Message,Kanban::Card`).
- **Port** — `--port` (default: an unused high port).

---

## Development

```bash
bin/setup                 # or: bundle install
bundle exec rake test     # minitest suite
bundle exec rubocop       # 37signals house style
```

The code is a small [Zeitwerk](https://github.com/fxn/zeitwerk)-autoloaded gem
under `lib/basecamp_agent_connector/`. External commands (`basecamp`,
`tailscale`) are reached through an injectable **command runner**, so the test
suite stubs that one subprocess boundary rather than mocking the gem’s own
classes.

```
bin/connect                          # executable shim → CLI.start(ARGV)
lib/basecamp_agent_connector/
  command_runner   # runs subprocesses; the seam tests stub
  basecamp_cli     # thin wrapper over the `basecamp` CLI (JSON in/out, profiles)
  identity         # resolve a Basecamp user by profile (agent / operator)
  tunnel           # Tailscale Funnel lifecycle (start / reset)
  webhooks         # register / delete webhooks across projects (with retry)
  server           # WEBrick server on the secret path; 200-fast
  event            # payload value object + the filter predicates
  verifier         # authoritative re-fetch + corroboration
  pipeline         # pre-filter → dedup → verify → emit
  emitter          # NDJSON writer
  cli              # arg parsing + orchestration + signal-driven teardown
skills/basecamp-connect/SKILL.md     # the /basecamp-connect skill
config/project_repos.toml            # project → repo mapping
test/                                # minitest, mirrors lib/
docs/spec.md                         # full design & decisions
```

See [`docs/spec.md`](docs/spec.md) for the complete design and the rationale
behind each decision.

## License

[MIT](LICENSE.txt).
