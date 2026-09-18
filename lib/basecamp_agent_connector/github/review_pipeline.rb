require "json"

# Turns one signed `pull_request_review` delivery into one emitted review:
# verify the HMAC, filter, dedup, re-fetch the review from the API, emit.
#
# What may travel is decided in `claimed_drop_reason` / `verified_drop_reason`:
# reviews on somebody else's pull request, the trust boundary (only the
# operator's approvals) and the agent's-own-reply drop. The trust boundary
# runs twice — on the claimed delivery as a cheap pre-filter, and again on
# the verified review, so it binds to the reviewer GitHub actually recorded
# rather than to the delivery body.
class BasecampAgentConnector::GitHub::ReviewPipeline
  def initialize(secret:, operator:, verifier:, emitter:, logger: $stderr)
    @secret = secret
    @operator = operator
    @verifier = verifier
    @emitter = emitter
    @logger = logger
    @seen_review_ids = Set.new
  end

  def process(body:, signature:)
    unless authentic?(body, signature)
      log "rejected delivery: invalid or missing signature"
      return
    end

    event = BasecampAgentConnector::GitHub::ReviewEvent.from_payload(JSON.parse(body))

    if actionable?(event)
      if (reason = claimed_drop_reason(event))
        log_dropped(event, reason)
      elsif fresh?(event)
        emit_if_verified(event)
      end
    end
  rescue JSON::ParserError => error
    log "ignored malformed payload: #{error.message}"
  end

  private
    def authentic?(body, signature)
      BasecampAgentConnector::GitHub::WebhookSignature.valid?(body: body, signature: signature, secret: @secret)
    end

    def actionable?(event)
      event.actionable_action? && event.actionable_state?
    end

    # Both gates return nil to let a review through, or the reason it is
    # dropped — which is also what STDERR says.
    #
    # The claimed delivery already names the pull request's author and the
    # reviewer, so both of those gates run here, before the API round trip.
    def claimed_drop_reason(event)
      other_authors_pull_request_reason(event) || unapproved_reason(event)
    end

    # The verified review carries the body *and* every inline comment, which
    # is what the agent's-own-reply drop has to read.
    def verified_drop_reason(event)
      unapproved_reason(event) || agent_reply_reason(event)
    end

    # The sibling of the drop below, and the wider one: a review on a pull
    # request somebody else opened is not this operator's work at all. The
    # connector watches whole repos, so every review anyone leaves on anyone's
    # PR in bc3 arrives here — eleven from other teams in one burst on the day
    # this was written — and each one woke a session to read a stranger's
    # feedback on a stranger's branch. The loop this feeds only ever acts on
    # the PRs the dispatched agent itself opened: it addresses the feedback in
    # that PR's worktree and lands the PR. There is no worktree, no branch and
    # no authority behind a review of somebody else's work.
    #
    # Unconditional, not a flag. The one case for the other side — the
    # operator was asked to review a colleague's PR — is the operator doing
    # the reviewing, and a review *they* wrote is still not work arriving for
    # their agent; the events it would let through are the colleague's replies
    # on their own branch, which the agent cannot act on either. An escape
    # hatch would buy back only noise, so there is nothing narrower worth
    # building. If acting on another author's PR ever becomes real work, it
    # wants a dispatch path of its own, not this one.
    #
    # The author is read off the delivery rather than re-fetched. The trust
    # boundary below re-checks the reviewer against the review the API hands
    # back because an emitted approval is merge authority; this gate is noise
    # removal, it can only ever drop, and the body it reads is HMAC-signed by
    # GitHub. `ReviewVerifier` copies `pull_request` from the delivery
    # verbatim, so checking again after the fetch would re-read the same bytes
    # — and checking before it saves the round trip entirely.
    #
    # An unknown author travels, like everything else here: a delivery with no
    # `pull_request.user` is a shape GitHub does not send, and guessing it is
    # a stranger's would drop a real review unseen.
    def other_authors_pull_request_reason(event)
      if !event.pull_author.nil? && !event.authored_by?(@operator)
        "on a pull request opened by #{event.pull_author.inspect}, not by the operator (#{@operator})"
      end
    end

    # Approvals are the trust boundary: an emitted `approved` review is what
    # lets the dispatched agent land the PR, so only the operator's approvals
    # pass. Feedback states carry no such authority and pass from anyone.
    def unapproved_reason(event)
      if event.approved? && !event.reviewed_by?(@operator)
        "approved by #{event.reviewer.inspect}, not by the operator (#{@operator})"
      end
    end

    # The mirror case, and it is noise rather than trust: a dispatched agent
    # commits and comments on GitHub under the operator's own account, so when
    # it answers a review thread on its own PR the connector emits a review
    # that wakes a session to read itself talking — most of the events in a
    # real day of running this.
    #
    # The account cannot tell those apart from the operator's own review
    # comments, because agent and operator share it. **The 🤖 prefix the
    # convention puts on agent-written PR comments is the signal**; the login
    # only narrows where to look. So a review is dropped when all three hold:
    # the operator's login, state `commented`, and its body and each of its
    # inline comments agent-marked. Anything written in it that does not start
    # with the marker is a person writing, and the whole review travels —
    # losing a human's review comment would be far worse than the noise this
    # removes, so every way the marker can be missing costs noise rather than
    # a comment. An approval still passes whatever it says: it is the signal
    # the whole loop rests on, and dropping it would strand every PR waiting
    # to land. So does `changes_requested`, which asks for work however it is
    # marked.
    #
    # `comments_complete?` is part of the test, not a technicality: a review
    # whose inline comments GitHub would not hand over might carry an unmarked
    # one, and this must never guess in that direction.
    #
    # Narrow enough to need no escape hatch: nothing a person writes is ever
    # dropped, so there is nothing for a flag to turn back on but the agent's
    # own replies.
    def agent_reply_reason(event)
      if event.commented? && event.reviewed_by?(@operator) && event.comments_complete? && event.agent_authored?
        "commented by the operator (#{@operator}), body and every inline comment " \
          "#{BasecampAgentConnector::GitHub::ReviewEvent::AGENT_PREFIX}-marked — the dispatched agent's own reply, not a person's"
      end
    end

    def fresh?(event)
      if @seen_review_ids.include?(event.id)
        false
      else
        @seen_review_ids << event.id
        true
      end
    end

    def emit_if_verified(event)
      verified = @verifier.verify(event)

      if verified.nil?
        log "dropped review #{event.id}: not corroborated by GitHub"
      elsif (reason = verified_drop_reason(verified))
        log_dropped(verified, reason)
      else
        @emitter.emit(verified)
      end
    end

    # The URL rides along so a drop is recoverable by hand: whoever reads the
    # log can open the review the connector decided not to dispatch.
    def log_dropped(event, reason)
      log "dropped review #{event.id}: #{reason}#{" (#{event.review_url})" if event.review_url}"
    end

    def log(message)
      @logger.puts message
    end
end
