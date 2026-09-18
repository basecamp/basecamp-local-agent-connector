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
bin/connect --repo acme/widgets --gh-operator marie                  # @marie's PRs and approvals, not this machine's gh login
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

A webhook is registered per **repo**, not per pull request, so every review
anyone leaves on anyone's PR in a watched repo arrives here. Only the ones on
the **operator's own** pull requests travel — see [Other people's pull
requests](#other-peoples-pull-requests). What follows is about the reviews that
survive that.

The signature proves GitHub sent the delivery, not that the reviewer may merge.
An emitted `approved` review is what lets the dispatched agent land the PR, so
`ReviewPipeline` admits an approval only when its reviewer is the **operator's
GitHub login** — every other reviewer's approval is dropped (logged to STDERR,
never emitted), exactly as the Basecamp side drops an unauthorized author
rather than emitting a flagged event. `changes_requested` and `commented`
reviews are feedback to address, not authority to merge, so they pass from any
reviewer — with the one exception below (the agent's own 🤖-marked replies). The gate runs twice: on the delivery
body as a cheap pre-filter, and again on the review re-fetched from the API, so
the decision binds to the `user.login` GitHub recorded, not to the POST body.
Logins compare case-insensitively, as GitHub does.

The operator's login is the one this machine's `gh` is authenticated as
(`gh api user`), resolved once at startup by `Connector#resolve_github_operator`;
`--gh-operator <login>` names another login instead, without consulting `gh`.
That one value answers every "who is the operator on GitHub" question the
pipeline asks — whose approvals are trusted, whose pull requests the loop is
about, whose 🤖-marked comment reviews are its agent's own — so there is no
second place to keep in step. The bridge logs the active set with the other
startup lines: `Trust: reviews on @<login>'s own pull requests only; approvals
from @<login> only; …`. A signed-out `gh` with no `--gh-operator` aborts
startup.

## Other people's pull requests

The webhook is per repo, so a repo like `basecamp/bc3` delivers every review on
every open PR in it — eleven from other teams in a single burst, the day this
was written. A review of a pull request the operator did not open is not work
for their agent: the loop here addresses feedback in the worktree of a PR the
agent itself opened and lands that PR, and there is no worktree, no branch and
no authority behind somebody else's. So `ReviewPipeline` drops a review whose
`pull_request.user.login` is not the operator's, whoever reviewed it and
whatever state it is in.

Three details:

- **Unconditional, no flag.** The case for the other direction — the operator
  was asked to review a colleague's PR — is the operator doing the *reviewing*,
  and their own review is not work arriving for their agent either; what the
  flag would let through is the colleague's replies on the colleague's branch,
  which the agent equally cannot act on. If acting on another author's PR ever
  becomes real work, it wants a dispatch path of its own rather than this one.
- **Read off the delivery, not re-fetched.** The approval gate re-checks the
  reviewer against the review the API hands back because an emitted approval is
  merge authority. This gate is noise removal: it can only ever drop, the body
  it reads is HMAC-signed by GitHub, and `ReviewVerifier` copies
  `pull_request` from the delivery verbatim — so a second check after the fetch
  would re-read the same bytes, while checking before it saves the round trip
  entirely. A drop here never asks GitHub anything.
- **An unknown author travels.** A delivery with no `pull_request.user` is a
  shape GitHub does not send, and reading it as a stranger's would drop a real
  review unseen. Logins compare case-insensitively, as everywhere else here.

```
dropped review 7001: on a pull request opened by "a-colleague", not by the operator (octocat) (https://github.com/acme/widgets/pull/12#pullrequestreview-7001)
```

## The agent's own replies (it posts under the operator's account)

A dispatched agent has no GitHub account of its own: it commits, comments and
replies to review threads under **the operator's**. So when it answers a review
thread on the PR it just opened, GitHub fires a `pull_request_review` with state
`commented` and the operator's login, the connector emits it, and the operator's
session wakes up to read the agent talking to itself. On a real day of running
this, that was most of the events in a long session.

The account cannot tell those apart from the operator's own review comments —
they share it. **The 🤖 prefix the convention puts on agent-written PR comments
can**, so the marker is the signal and the login only narrows where to look.
`ReviewPipeline` drops a review when all three hold:

1. its reviewer is the operator's GitHub login,
2. its state is `commented`, and
3. it carries text, and every piece of that text — the body and each inline
   comment, each taken whole — starts with 🤖. (Blank ones count for nothing
   either way; a review with nothing written in it is nobody's word and
   travels.)

Anything written in it that does not start with 🤖 means a person is writing,
and the whole review travels, the agent's parts with it. Losing a human's
review comment would be far worse than the noise this removes, so the rule
fails toward emitting:

| Review | Verdict |
|---|---|
| operator, `commented`, body and every inline comment 🤖-marked | **dropped** (logged to STDERR) — the agent's own reply |
| operator, `commented`, anything written without the marker | **emitted** — a person wrote it, mixed reviews included |
| operator, `approved` | **emitted** — the trust signal the loop rests on; dropping it would strand every PR waiting to land |
| operator, `changes_requested` | **emitted** — work to do, however it is marked |
| anyone else, `approved` | dropped — see [Trust](#trust) |
| anyone else, any feedback state | **emitted** — Copilot's review of each push arrives here, 🤖 or not |

Every row above is a review of the operator's own pull request; a review of
anyone else's is dropped before any of this — see [Other people's pull
requests](#other-peoples-pull-requests).

Unlike the approval gate, this one runs **only on the review re-fetched from the
API**: the delivery carries the body but none of the inline comments, and an
unmarked inline comment is a person's feedback that must not be dropped
unseen. For the same reason the re-fetch reads **every page** of them, and a
comment list GitHub would not hand over at all blocks the drop rather than
passing for an empty one — "there are no inline comments" and "the list
could not be read" are different facts, and only the first can support
dropping anything. A drop prints its reason to STDERR like every other drop:

```
dropped review 7001: commented by the operator (octocat), body and every inline comment 🤖-marked — the dispatched agent's own reply, not a person's (https://github.com/acme/widgets/pull/12#pullrequestreview-7001)
```

The URL is there so a drop is recoverable by hand. The marker is read per
piece of text, not per line: a body is one piece with one author, so a review
body that opens with 🤖 counts as the agent's however many paragraphs follow.
Reading it line by line would be the wrong trade — agents write multi-line
replies with a single leading marker, so nothing would ever be dropped — and
the case it would guard against, a person writing their own review with 🤖 as
the very first thing in it, is both rare and visible in the log.

There is no flag to turn this off, and it needs none: nothing a person writes is
ever dropped, so an escape hatch would only restore the agent's own replies.

The marker convention lives with the agents, not in this repo, and the drop
leans on it without enforcing it — which is why every way it can be absent
costs noise and never a comment. An agent that marks nothing, a `--gh-operator`
naming a login other than the one the local agents post under, a marker behind
a quote or a bold span rather than first: in each case the drop simply never
fires and the event arrives as it did before. The one thing it will not do is
guess that unseen text was the agent's: a comment list GitHub would not hand
over blocks the drop too.

Nothing about Basecamp events changes.

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
   `Emitter`. A review of a pull request the operator did not open is dropped
   without asking GitHub anything, an `approved` review is emitted only when
   the re-fetched reviewer is the operator's GitHub login, and an all-🤖
   `commented` review by that login is dropped as the agent's own reply —
   `GitHub::ReviewPipeline`.
5. **Tear down** the repo webhook on `SIGINT`/`SIGTERM`, like the Basecamp
   webhooks and the funnel.

### Emitted STDOUT format

```json
{"review_id":7001,"action":"submitted","state":"changes_requested",
 "repo":"acme/widgets","pull_number":12,"reviewer":"octocat",
 "body":"please fix the naming","html_url":"https://github.com/acme/widgets/pull/12#pullrequestreview-7001",
 "comments":[{"path":"lib/x.rb","line":3,"body":"rename this"}]}
```

`state` is always the lowercase form above. GitHub's webhook delivers it
lowercase but the REST re-fetch returns `APPROVED` / `CHANGES_REQUESTED` /
`COMMENTED`; `ReviewEvent` normalizes both, so the reviewer gate and the
emitted line read the same value.

## What the dispatched agent does

Per emitted review event, the front thread dispatches a fresh agent (same
orchestrator/worker split as the Basecamp flow):

- **`changes_requested` / `commented`** → re-fetch the full review, address it in
  the task's worktree, re-green (`bin/ci` local + `gh pr checks --watch` remote),
  push, and reply. The agent's own 🤖-marked replies do not come back as
  events; a review with any unmarked text does, whoever wrote it.
- **`approved`** → land per the repo's policy, reply done. Only the operator's
  approvals reach the agent; the connector drops everyone else's.

## Open questions

- **Webhook scope** — one repo hook per PR-creating task, or one per repo reused
  across tasks? (Per-repo reuse is cleaner; needs ref-counting for teardown.)
- **`approved` action** — auto-merge vs. mark-ready vs. just notify; per-repo
  policy or a connector flag.
- **Correlating an event to its task/worktree** — map PR number → worktree/branch
  so the feedback agent resumes in the right place.
