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
   npx skills add basecamp/basecamp-local-agent-connector       # this project only
   npx skills add basecamp/basecamp-local-agent-connector -g    # user-level, all projects
   ```

   (Or just run Claude Code from a clone of this repo — the skill is
   auto-discovered via `.claude/skills`.)

   **Updating:** the install is a snapshot copy fetched from GitHub, so editing
   this repo does *not* change an installed skill. After changes land on `main`,
   refresh with:

   ```bash
   npx skills update -g    # or without -g for a project-level install
   ```

2. **The runtime** — clone the repo and install dependencies:

   ```bash
   git clone https://github.com/basecamp/basecamp-local-agent-connector
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

**Watch several projects at once** — repeat `--project` (name, URL, or ID).
A single connector run registers one webhook per project and multiplexes them all
onto one funnel path, so the same `@agent` watches every listed project simultaneously:

```
/basecamp-connect @Clawdito --project "BC5.1" --project "On Call" --project 20361308
```

- `--project` takes a **name, URL, or ID** — the CLI resolves it.
- Watch GitHub PR reviews too, over the **same** server: add `--repo <owner>/<repo>`
  (repeatable). You need at least one `--project` or `--repo`; `--project` also
  needs an `@agent`.

### Stopping (and why it matters)

While running, the connector exposes a **public URL** (via Tailscale Funnel) and
registers a **real webhook** on each watched project. **Always stop it when
you’re done** — stopping deletes every webhook and unmounts its funnel paths
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
                                     • boosts the recording `On it!` as the agent (the ack)
                                     • resolves the local repo from the project
                                     • dispatches a background Claude agent in that repo
                                       (which gathers context via the `basecamp` CLI)
                                     • replies on the card as the agent (--profile)
```

Two halves, deliberately separated:

1. **`bin/connect`** — the **bridge**. A small Ruby process: it opens the public
   endpoint, registers the webhooks, and does the *security-critical* filtering
   and verification. It emits only trusted events as NDJSON and touches nothing
   else.
2. **`/basecamp-connect`** — the **driver**. A Claude Code skill that runs the
   bridge, reads its output, acks each event with a boost as the agent, turns it
   into a background-agent task in the right repo, and posts the reply.

The bridge is dumb-and-safe; the driver is smart-and-contextual. You can run
`bin/connect` on its own to see exactly what would be dispatched.

---

## Security mechanisms

What `bin/connect` has in place, at a glance:

- **Operator-only triggering by default** — with no trust flags, an event acts
  only when its creator is the operator (the CLI default profile, or
  `--operator <profile>`), matched by email or account Person id (bc3 redacts
  other users' emails from non-admin viewers, so the id is the key that always
  works). Trust can be **deliberately broadened** per run — see
  [Trust modes](#trust-modes) below.
- **Agent-self exclusion** — the agent's own identity never authorizes, in any
  mode, matched by email *and* Person id. Even when trust is broadened to a
  domain or project the agent belongs to, its own posts cannot re-trigger it.
- **Assignments stay operator-only** — assigning the agent a card/todo is
  higher-privilege (the assigner's identity is not corroborated), so broadened
  modes apply to mentions only unless `--allow-assignments-from-authorized`
  explicitly opts assignments in.
- **Mention gating** — the recording must contain a real Basecamp mention
  *attachment* (`application/vnd.basecamp.mention`) for the agent user, matched by
  the agent's Person id encoded in the mention SGID.
- **Subscription gating** — a new comment with *no* mention still triggers when
  the agent subscribes to the commented-on recording (a card/thread it
  participates in). Subscription is a live API fact, so it is confirmed by
  re-fetching the parent's subscribers and matching the agent's Person id — never
  taken from the payload. The comment author is gated exactly like a mention
  (operator by default, or the active trust mode's authors).
- **Boost gating** — a boost on the agent's work triggers only when a fresh
  fetch of the **agent's own received-boosts feed** contains it: boosts never
  arrive by webhook (polling that feed is the delivery mechanism), and the feed
  files a boost under the person it was aimed at, so membership is both the
  existence proof and the targeting proof. The booster is gated exactly like a
  mention author — matched by Person id, since the agent's view of the feed
  redacts other users' emails — and the emitted booster/content come from the
  fetch, never from a payload. Email-keyed trust modes (`allowlist`, `domain`)
  can't see through that redaction, so under them boosts effectively stay
  operator-only; `project` mode broadens boosts fine.
- **API corroboration** — every event is re-fetched from the Basecamp API and the
  **authoritative fetched copy is what gets acted on**, never the raw POST body.
  For a mention the fetched recording carries the authoritative creator *and*
  content, so both the author and the mention are re-checked against it. An
  assignment corroborates the agent's live assignee state but keeps the POST's
  claimed assigner — see the assignment caveat under [Trust modes](#trust-modes).
- **Secret webhook path** — the server accepts only `POST /bc5/<secret>`, where
  `<secret>` is a fresh 128-bit random token generated per run; every other path
  returns 404.
- **Localhost binding** — WEBrick listens only on `127.0.0.1`; the sole public
  ingress is the Tailscale Funnel over HTTPS.
- **Replay de-duplication** — events are de-duplicated by id within a run.
- **No reply loop** — the agent's own identity never authorizes in any mode (an
  explicit guard on email and Person id), so replies posted as the agent can't
  re-trigger the connector even under `domain`/`project` trust where the agent
  shares the domain or is a project member; in operator mode they also simply
  fail the author check. Startup warns if the agent and operator resolve to the
  same user.
- **Ephemeral exposure** — the funnel and per-project webhooks exist only while
  the process runs and are torn down on exit.

---

## Trust & security model

A webhook payload is attacker-influenceable text that flows into an agent which
can run commands. `bin/connect` emits an event only when **all** of these hold:

1. **Authored by an authorized user.** By default that means *you* alone (the
   CLI default profile, or `--operator <profile>`), matched by email or account
   Person id: a third party who can comment in the project cannot make your
   agent do anything.
   Trust modes (below) can deliberately extend this to named colleagues, a
   domain, or the whole project membership — and for a **mention** the check is
   applied **twice**: once on the claimed webhook payload as a cheap pre-filter,
   and again on the corroborated event, so authorization binds to the author
   Basecamp actually recorded, never to forgeable POST text. (An **assignment**
   corroborates the agent's assignee state but not the assigner — see the
   assignment caveat under [Trust modes](#trust-modes).)
2. **Targets the agent.** The event must reach the agent one of four ways:
   a real Basecamp mention *attachment* (`application/vnd.basecamp.mention`)
   naming it (not loose text that happens to contain the name); an assignment
   adding it to a card/todo; a **new comment on a recording the agent
   subscribes to**; or a **boost on the agent's work**. Mentions are re-checked
   on the corroborated recording, so a forged mention paired with a real
   un-mentioning recording is dropped; subscription is re-fetched from the live
   subscribers API and stamped by the verifier, so a comment the agent doesn't
   actually subscribe to is dropped the same way; a boost is stamped only when
   the verifier finds it in a fresh fetch of the agent's own received-boosts
   feed — the feed files a boost under the person it was aimed at, so
   membership is the targeting fact.
3. **Corroborated by Basecamp.** The recording is re-fetched from the Basecamp
   API and confirmed. For a mention that means it exists **with the claimed
   creator and the claimed mention** — so a forged POST cannot survive. For an
   assignment it means the agent is really among the recording's current
   assignees; the assigner's identity is not independently corroborated, so
   there the secret URL path — a fresh 128-bit token per run — is the gate that
   stops a forged operator-assignment, not corroboration.

For a mention, the content acted on is the **authoritative copy fetched from
Basecamp**, never the raw POST body.

**No reply loop.** Replies are posted *as the agent*, a different user than the
operator. The agent's own identity **never authorizes, in any mode** — an
explicit guard, matched by email and Person id, refuses agent-authored events
before any mode is consulted. So even under `--trust domain` (where the agent's
email may share the domain) or `--trust project` (where the agent is a member),
its own replies can never re-trigger the connector. (`bin/connect` warns at
startup if the agent and operator resolve to the same Basecamp user — a
configuration in which nothing can trigger.)

### Trust modes

Who may drive the agent is a per-run, explicit choice. The agent acts with the
operator's full machine authority, so broadening trust means handing that
authority to more people — the startup log prints the active mode and the
concrete allowed set so it is never implicit.

| Mode | Who triggers | CLI |
|------|--------------|-----|
| `operator` *(default)* | You only. No flags = exactly this. | — |
| `allowlist` | You + the named emails. | `--allow marie@37signals.com` (repeatable or comma-separated; implies the mode, or `--trust allowlist`) |
| `domain` | Any author whose email is at a listed domain. | `--allow-domain 37signals.com` (repeatable), or bare `--trust domain` for the 37signals.com default |
| `project` | Any corroborated non-client author of a recording the operator's account can read (client users excluded, fail-closed). | `--allow-project` or `--trust project` |

Every mode implicitly includes the operator and excludes the agent itself. In
`project` mode, membership is proven by corroboration: only project members can
post in a project, and every event is re-fetched from the Basecamp API before it
acts — a person who cannot post there cannot produce a corroborated recording.
**Client (external) users are excluded fail-closed**: the corroborated recording
must positively report `creator.client == false`; an absent or non-boolean flag
is treated as untrusted, so a recording representation that omits it cannot slip
a client author through.

One limit of `project` mode is worth stating plainly, because it matters only
against the forged-POST-with-leaked-secret-path threat (a normal Basecamp
delivery is unaffected): **corroboration proves the recording exists with that
author, not that it lives in a *watched* project.** The API re-fetch follows the
URL in the payload, and the operator's CLI can read recordings beyond the
watched projects. So `project` mode trusts any corroborated non-client author in
*any* project the operator's account can see, not strictly the watched ones.
Prefer `allowlist`/`domain` when you need the trust set pinned to specific
people.

**Assignments are operator-only in every mode** unless
`--allow-assignments-from-authorized` opts the mode's authors in. An assignment
is corroborated by the agent really being among the card's assignees — but the
*assigner's* identity is **not** independently verifiable: the verifier confirms
live assignee state and preserves the event's claimed creator. Against a forged
POST on a leaked secret path, that means the "operator-only" guarantee for the
assignment trigger rests on the secret path, not on corroboration, in a way the
mention trigger does not. Bear that in mind before opting assignments in, and
prefer the mention trigger when the author must be cryptographically pinned to
the recording.

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
| `--trust` | Trust mode: `operator`, `allowlist`, `project`, or `domain`. Usually inferred from the value flags below. | `operator` |
| `--allow` | Author email to trust (repeatable or comma-separated). Implies `--trust allowlist`. | — |
| `--allow-domain` | Email domain to trust (repeatable or comma-separated). Implies `--trust domain`. | `37signals.com` under bare `--trust domain` |
| `--allow-project` | Trust any corroborated non-client author of a recording the operator's account can read. Implies `--trust project`. | off |
| `--allow-assignments-from-authorized` | Let any authorized author trigger via assignment, not just the operator. | off — assignments are operator-only |
| `--types` | Comma-separated Basecamp event types to subscribe to. `Chat::Line` selects Campfire coverage — chat has no webhooks, so the connector polls each watched project's chats for it. | `Comment,Message,Kanban::Card,Kanban::Step,Todo,Chat::Line` |
| `--chat-poll` | Campfire poll interval, in seconds. | `15` |
| `--boost-poll` | Received-boosts poll interval, in seconds. Boosts have no webhooks, so the connector polls the agent's own received-boosts feed for them. | `60` |
| `--no-boosts` | Don't poll the agent's received-boosts feed (no boost trigger). | polling on |
| `--port` | Local port for the webhook server. | an unused high port |

**What it does, in order:**

1. **Resolve agent & operator.** Validates the agent name maps to a usable local
   profile (`basecamp me --profile <agent>`); if not, it aborts with
   `Run basecamp auth login --profile <agent>…`. Resolves the operator identity
   (refreshing an expired token once). Warns if agent == operator.
2. **Open the endpoint.** Starts a WEBrick server on `127.0.0.1:<port>` that only
   accepts `POST /bc5/<random-secret>`; everything else is 404. One server + one
   secret path serves every watched project.
3. **Expose it.** `tailscale funnel --set-path` mounts each of the connector's
   paths (`/bc5/<secret>`, plus `/gh/<secret>` when watching repos) on this
   host's funnel, publishing the server at a public `https://<host>.ts.net` URL.
   Only those paths are touched, so funnel paths other tools mounted keep
   working.
4. **Register webhooks.** Creates one webhook per project (with retry on transient
   failures), recording their IDs for cleanup. Also starts the **boost poller**
   (unless `--no-boosts`): boosts have no webhooks, so the agent's own
   received-boosts feed is fetched every `--boost-poll` seconds and each new
   boost runs the same pipeline as a webhook delivery. The first fetch is a
   baseline — history is never dispatched.
5. **Listen.** For each delivery, on the request thread: pre-filter
   (authorized author + mentions agent + actionable kind), de-duplicate by
   event id, verify against the Basecamp API, re-check that the
   **corroborated** author is authorized, and **print the trusted event as one
   line of NDJSON** to STDOUT. Dropped/diagnostic lines go to STDERR. The
   delivery is answered with the verdict: `200` once the event is settled
   (emitted, dropped, or a duplicate), `503` when Basecamp could not be asked —
   the connector re-runs the CLI a few times first (its keyring probe loses a
   race under concurrent invocations and reports stale credentials; bc3 may
   answer 5xx mid-deploy), and a `503` makes bc3's delivery job redeliver the
   event with backoff rather than settling it as uncorroborated. A delivery
   that stays unanswerable for all of bc3's 10 attempts (~4.3h — a revoked
   credential looks just like the race) makes bc3 deactivate the webhook: fix
   the CLI's credentials (`basecamp auth status --profile <agent>`) and
   restart `bin/connect`, which re-registers it. The connector logs that
   remedy with every `503`.

**Emitted event (STDOUT, one JSON object per line):**

```json
{"event_id":99001,"kind":"comment_created","created_at":"…",
 "creator":{"id":100,"name":"Jorge Manrubia","email_address":"jorge@…"},
 "recording":{"id":456,"type":"Comment","app_url":"…","url":"…",
   "content":"<p>… <bc-attachment content-type=\"application/vnd.basecamp.mention\">…Clawdito…</bc-attachment> fix X</p>",
   "parent":{…},"bucket":{"id":222,"name":"BC5 Calendar"}},
 "trigger":{"mentioned":true,"subscribed":false}}
```

`trigger` is the connector's own verdict on why the event targets the agent,
settled on the re-fetched recording: `mentioned` when its content carries a
mention attachment for the agent's Person id, `subscribed` when a
`comment_created` fired because the agent subscribes to the commented-on
recording. A `comment_created` is exactly one of the two. An assignment or a
boost is a directive by `kind` alone: `subscribed` is `false` for both, and
`mentioned` is a fact about the content (an assigned card whose description
mentions the agent reads `true`; a boost is a reaction, not content, so the
boost path settles no mention verdict and it always reads `false`). A watcher
reads `trigger` to tell a directive from
followed-thread activity instead of decoding the mention markup itself.

**Teardown.** On `SIGINT`/`SIGTERM` it deletes **every** registered webhook
(best-effort, reporting any it couldn’t) and unmounts its own funnel paths
(`tailscale funnel --set-path <path> off` — never `funnel reset`, which would
also tear down other tools' paths), then stops the server. The mounted paths and
webhooks live only for the lifetime of the process. If it
is ever `SIGKILL`ed, clean up manually:

```bash
basecamp webhooks list   --project "<project>"        # find leftovers
basecamp webhooks delete <id> --project "<project>"
tailscale funnel status                              # find leftover /bc5/… and /gh/… paths
tailscale funnel --set-path /bc5/<secret> off
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
- **Trust mode** — who beyond the operator may trigger; defaults to nobody.
  See [Trust modes](#trust-modes).
- **Project → repo mapping** — [`config/project_repos.toml`](config/project_repos.toml)
  maps Basecamp project-name tokens to local repo paths. The skill uses it to
  decide where to run each agent; if nothing matches, it asks you.
- **Event types** — `--types` (default `Comment,Message,Kanban::Card,Kanban::Step,Todo,Chat::Line`).
  `Chat::Line` is Campfire coverage: Basecamp delivers no chat webhooks, so the
  connector polls each watched project's chats and runs new lines through the
  same trust gate as webhook events.
- **Boost polling** — `--boost-poll` interval in seconds (default 60), or
  `--no-boosts` to disable the boost trigger. Boosts have no webhooks, so the
  connector polls the agent's own received-boosts feed — an account-wide,
  agent-scoped surface (a boost triggers wherever the agent's boosted work
  lives, not only in watched projects).
- **Port** — `--port` (default: an unused high port).

---

## Development

```bash
bin/setup                 # or: bundle install
bundle exec rake test     # minitest suite
bundle exec rubocop       # 37signals house style
```

The code is a small [Zeitwerk](https://github.com/fxn/zeitwerk)-autoloaded gem
under `lib/basecamp_agent_connector/`. Transport-agnostic pieces live at the top
level; the two transports are namespaced under `Basecamp::` and `GitHub::`.
External commands (`basecamp`, `gh`, `tailscale`) are reached through an
injectable **command runner**, so the test suite stubs that one subprocess
boundary rather than mocking the gem’s own classes.

```
bin/connect                          # shim → Connector.start(ARGV) — Basecamp and/or GitHub
lib/basecamp_agent_connector/
  connector        # unified: one multi-route server on shared-funnel paths, mounts each transport's bridge
  command_runner   # shared: runs subprocesses; the seam tests stub
  server           # shared: WEBrick server, path→handler routes; answers the handler's status, raw body + headers
  tunnel           # shared: mounts/unmounts our own paths on the host's Tailscale Funnel
  emitter          # shared: NDJSON writer
  basecamp/        # Basecamp:: — the Basecamp webhook transport
    bridge         #   one route: secret path, register webhooks, handler, teardown
    client         #   thin wrapper over the `basecamp` CLI (JSON in/out, profiles)
    identity       #   resolve a Basecamp user by profile (agent / operator)
    webhooks       #   register / delete webhooks across projects (with retry)
    event          #   payload value object + the filter predicates
    verifier       #   authoritative re-fetch + corroboration
    pipeline       #   pre-filter → dedup → verify → emit
  github/          # GitHub:: — the PR review-loop transport
    bridge             #   one route: secret path + HMAC, register repo hooks, handler, teardown
    client             #   thin wrapper over the `gh` CLI (JSON in/out)
    webhooks           #   register / delete repo webhooks (with retry)
    webhook_signature  #   constant-time X-Hub-Signature-256 HMAC verify
    review_event       #   pull_request_review payload value object
    review_verifier    #   re-fetch the review + inline comments
    review_pipeline    #   verify signature → filter → dedup → re-fetch → emit
skills/basecamp-connect/SKILL.md     # the /basecamp-connect skill
config/project_repos.toml            # project → repo mapping
test/                                # minitest, mirrors lib/
docs/spec.md                         # full design & decisions
```

See [`docs/spec.md`](docs/spec.md) for the complete design and the rationale
behind each decision.

## License

[MIT](LICENSE.txt).
