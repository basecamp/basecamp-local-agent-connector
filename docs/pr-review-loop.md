# PR review loop — GitHub webhook ingestion (design)

When a `/basecamp-connect` task opens a pull request, the agent gets it **green
before reporting done** (see `SKILL.md` → "When the task results in a pull
request"). After that, the PR's **reviews** drive a follow-up loop: address
requested changes, or land on approval. This note specs how the connector
ingests those reviews.

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

The shapes already exist in `lib/`; the GitHub path adds analogues:

1. **Register** a repo webhook for `pull_request_review` pointed at the funnel
   (`gh api repos/{o}/{r}/hooks` with a generated `secret`), recording its id —
   like `webhooks.rb` does for Basecamp.
2. **Receive** the POST on the existing server (a `/gh/<secret>` path), respond
   200 fast.
3. **Verify** `X-Hub-Signature-256` against the secret; reject otherwise.
4. **Re-fetch + emit** the whole review as one NDJSON event (PR number, repo,
   `review.state`, body, inline comments, author) — a `verifier.rb`/`emitter.rb`
   analogue.
5. **Tear down** the repo webhook on `SIGINT`/`SIGTERM`, like the Basecamp
   webhooks and the funnel.

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
