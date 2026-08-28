# PR review loop — GitHub webhook ingestion

When a `/basecamp-connect` task opens a pull request, the agent gets it **green
before reporting done** (see `SKILL.md` → "When the task results in a pull
request"). After that, the PR's **reviews** drive a follow-up loop: address
requested changes, or land on approval. This note describes how the connector
ingests those reviews — **implemented as a route on the unified `bin/connect`**.

## Usage

`bin/connect` is unified: one process, one Tailscale Funnel, one server that
multiplexes Basecamp and GitHub by path. Watch repos by passing `--repo`,
alongside (or instead of) Basecamp `--project`:

```bash
bin/connect @Clawdito --project "BC5 Calendar" --repo basecamp/bc3   # both at once
bin/connect --repo basecamp/bc3 --repo acme/widgets                  # GitHub only
bin/connect --repo acme/widgets --gh-operator marie                  # approvals by @marie, not this machine's gh login
```

It registers a `pull_request_review` webhook on each repo (against the shared
funnel) and prints one NDJSON line per trusted, corroborated review to STDOUT —
the same stream as Basecamp events — and tears every webhook + the funnel down on
`SIGINT`/`SIGTERM`. Default event: `pull_request_review`.

Because it's one funnel for everything, a repo created **after** startup doesn't
need a second process: the GitHub route logs its `/gh/<secret>` endpoint + HMAC
secret, and you register a webhook on the new repo against that endpoint (one
webhook per PR's repo, all multiplexed onto the single funnel).

## Why webhooks, not polling

A human review is **unbounded latency** (minutes to days). Two non-options:

- An **LLM agent in a poll loop** burns tokens every wake-up, holds a context
  window the whole time, and dies when the session ends.
- A **scheduled routine** survives the session but can't drive the *local* agent
  / local `bin/ci`.

GitHub **push**es review events. We already run a public Tailscale Funnel and
already turn inbound webhooks into dispatch events — so a GitHub
`pull_request_review` webhook on that same endpoint is the architecturally
consistent fit. The agent only spins up when there is something to do.

## The events

"Review feedback" is spread across event types. React to the review as the unit:

| Event | Fires for |
|---|---|
| `pull_request_review` | A submitted review — `review.state` ∈ `approved`, `changes_requested`, `commented` (with the body) |
| `pull_request_review_comment` | Inline diff-line comments |
| `issue_comment` | Plain PR conversation comments |

A single review with N inline comments fires **one** `pull_request_review` plus
**N** `pull_request_review_comment` events. **Do not assemble partial events.**
Trigger on `pull_request_review` (`action: submitted`) and then **re-fetch the
whole review** from the API — body + all inline comments — as one unit:

```bash
gh pr view <n> --json reviewDecision,latestReviews,reviews
gh api repos/{owner}/{repo}/pulls/<n>/comments     # inline review comments
```

This mirrors the Basecamp transport's "webhook = trigger + pointer, API = source
of truth" (`verifier.rb`): no racing, no ordering games.

## Trust

GitHub signs deliveries with an HMAC secret (`X-Hub-Signature-256`) — stronger
than Basecamp webhooks, which carry **no** signature (the reason that side leans
on API re-fetch). So this side gets **both**: verify the signature on receipt,
then corroborate by re-fetching the review via the API. Only the operator's
repos and only the operator's approvals are actionable.

The signature proves GitHub sent the delivery, not that the reviewer may merge.
An emitted `approved` review is what lets the dispatched agent land the PR, so
`ReviewPipeline` admits an approval only when its reviewer is the **operator's
GitHub login** — every other reviewer's approval is dropped (logged to STDERR,
never emitted), exactly as the Basecamp side drops an unauthorized author
rather than emitting a flagged event. `changes_requested` and `commented`
reviews are feedback to address, not authority to merge, so they pass from any
reviewer. The gate runs twice: on the delivery body as a cheap pre-filter, and
again on the review re-fetched from the API, so the decision binds to the
`user.login` GitHub recorded, not to the POST body. Logins compare
case-insensitively, as GitHub does.

The operator's login is the one this machine's `gh` is authenticated as
(`gh api user`), resolved once at startup; `--gh-operator <login>` names
another login instead, without consulting `gh`. The bridge logs the active set
with the other startup lines: `Trust: approvals from @<login> only; …`. A
signed-out `gh` with no `--gh-operator` aborts startup.

## Connector plumbing (parallels the Basecamp side)

The top-level `Connector` owns the one funnel + one server and mounts each
transport as a `Bridge` (a route: secret path + webhook registration + handler +
teardown). GitHub-specific code lives under `GitHub::`, Basecamp-specific under
`Basecamp::`, and the transport-agnostic pieces stay top-level — each GitHub
class mirrors its Basecamp counterpart:

| `GitHub::` | `Basecamp::` counterpart | Role |
|---|---|---|
| `Bridge` | `Bridge` | One route on the shared server: secret path, register webhooks, handler, teardown |
| `Client` | `Client` | Wrap the external CLI (`gh` / `basecamp`) |
| `Webhooks` | `Webhooks` | Register/delete hooks (with retry) |
| `WebhookSignature` | — (Basecamp has none) | Verify the `X-Hub-Signature-256` HMAC |
| `ReviewEvent` | `Event` | Parse the delivery payload |
| `ReviewVerifier` | `Verifier` | Re-fetch the authoritative record |
| `ReviewPipeline` | `Pipeline` | Verify → filter → dedup → re-fetch → emit |
| `Connector`, `Server`, `Tunnel`, `Emitter`, `CommandRunner` | shared (top-level) | One funnel + one multi-route server for both |

The flow, per delivery:

1. **Register** a repo webhook for `pull_request_review` pointed at the funnel
   (`gh api repos/{o}/{r}/hooks` with a generated HMAC `secret`), recording its
   id — `GitHub::Webhooks`.
2. **Receive** the POST on the server at `/gh/<path-secret>`, respond 200 fast —
   `Server` hands the handler the raw body + headers.
3. **Verify** `X-Hub-Signature-256` against the HMAC secret (constant-time);
   reject otherwise — `GitHub::WebhookSignature`.
4. **Re-fetch + emit** the whole review as one NDJSON event (review id, action,
   state, repo, PR number, reviewer, body, inline comments) — `GitHub::ReviewVerifier` +
   `Emitter`. An `approved` review is emitted only when the re-fetched
   reviewer is the operator's GitHub login — `GitHub::ReviewPipeline`.
5. **Tear down** the repo webhook on `SIGINT`/`SIGTERM`, like the Basecamp
   webhooks and the funnel.

### Emitted STDOUT format

```json
{"review_id":7001,"action":"submitted","state":"changes_requested",
 "repo":"acme/widgets","pull_number":12,"reviewer":"octocat",
 "body":"please fix the naming","html_url":"https://github.com/acme/widgets/pull/12#pullrequestreview-7001",
 "comments":[{"path":"lib/x.rb","line":3,"body":"rename this"}]}
```

## What the dispatched agent does

Per emitted review event, the front thread dispatches a fresh agent (same
orchestrator/worker split as the Basecamp flow):

- **`changes_requested` / `commented`** → re-fetch the full review, address it in
  the task's worktree, re-green (`bin/ci` local + `gh pr checks --watch` remote),
  push, and reply.
- **`approved`** → land per the repo's policy, reply done. Only the operator's
  approvals reach the agent; the connector drops everyone else's.

## Open questions

- **Webhook scope** — one repo hook per PR-creating task, or one per repo reused
  across tasks? (Per-repo reuse is cleaner; needs ref-counting for teardown.)
- **`approved` action** — auto-merge vs. mark-ready vs. just notify; per-repo
  policy or a connector flag.
- **Correlating an event to its task/worktree** — map PR number → worktree/branch
  so the feedback agent resumes in the right place.
