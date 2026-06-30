# PR review loop — GitHub webhook ingestion

When a `/basecamp-connect` task opens a pull request, the agent gets it **green
before reporting done** (see `SKILL.md` → "When the task results in a pull
request"). After that, the PR's **reviews** drive a follow-up loop: address
requested changes, or land on approval. This note describes how the connector
ingests those reviews — **implemented as `bin/gh-review`**.

## Usage

```bash
bin/gh-review <owner/repo> [<owner/repo> ...] [--events EVENTS] [--port PORT]
```

It opens a Tailscale Funnel, registers a GitHub webhook on each repo, and prints
one NDJSON line per trusted, corroborated review to STDOUT — watch it exactly
like `bin/connect` and dispatch a fresh agent per event. It tears the webhooks
and funnel down on `SIGINT`/`SIGTERM`. Default event: `pull_request_review`.

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

## Connector plumbing (parallels the Basecamp side)

GitHub-specific code lives under the `GitHub::` namespace, Basecamp-specific code
under `Basecamp::`, and the transport-agnostic pieces stay top-level — each
GitHub class mirrors its Basecamp counterpart:

| `GitHub::` | `Basecamp::` counterpart | Role |
|---|---|---|
| `ReviewCLI` (`bin/gh-review`) | `CLI` (`bin/connect`) | Orchestrate funnel → register → listen → teardown |
| `Client` | `Client` | Wrap the external CLI (`gh` / `basecamp`) |
| `Webhooks` | `Webhooks` | Register/delete hooks (with retry) |
| `WebhookSignature` | — (Basecamp has none) | Verify the `X-Hub-Signature-256` HMAC |
| `ReviewEvent` | `Event` | Parse the delivery payload |
| `ReviewVerifier` | `Verifier` | Re-fetch the authoritative record |
| `ReviewPipeline` | `Pipeline` | Verify → filter → dedup → re-fetch → emit |
| `Server`, `Tunnel`, `Emitter`, `CommandRunner` | shared (top-level) | Reused as-is |

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
   `Emitter`.
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
- **`approved`** → land per the repo's policy, reply done.

## Open questions

- **Webhook scope** — one repo hook per PR-creating task, or one per repo reused
  across tasks? (Per-repo reuse is cleaner; needs ref-counting for teardown.)
- **`approved` action** — auto-merge vs. mark-ready vs. just notify; per-repo
  policy or a connector flag.
- **Correlating an event to its task/worktree** — map PR number → worktree/branch
  so the feedback agent resumes in the right place.
