require "json"

# Turns one signed `pull_request_review` delivery into one emitted review:
# verify the HMAC, filter, dedup, re-fetch the review from the API, emit.
#
# What may travel is decided in `claimed_drop_reason` / `verified_drop_reason`:
# the trust boundary (only the operator's approvals) and the agent's-own-reply
# drop. The trust boundary runs twice — on the claimed delivery as a cheap
# pre-filter, and again on the verified review, so it binds to the reviewer
# GitHub actually recorded rather than to the delivery body.
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
    # The claimed delivery can only be judged on reviewer and state, so the
    # trust boundary alone runs here.
    def claimed_drop_reason(event)
      unapproved_reason(event)
    end

    # The verified review carries the body *and* every inline comment, which
    # is what the agent's-own-reply drop has to read.
    def verified_drop_reason(event)
      unapproved_reason(event) || agent_reply_reason(event)
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
    # the operator's login, state `commented`, and every line written in it
    # agent-marked. A line that does not start with the marker is a person
    # writing, and the whole review travels — losing a human's review comment
    # would be far worse than the noise this removes, so every way the marker
    # can be missing costs noise rather than a comment. An approval still
    # passes whatever it says: it is
    # the signal the whole loop rests on, and dropping it would strand every
    # PR waiting to land. So does `changes_requested`, which asks for work
    # however it is marked.
    #
    # Narrow enough to need no escape hatch: nothing a person writes is ever
    # dropped, so there is nothing for a flag to turn back on but the agent's
    # own replies.
    # `comments_complete?` is part of the test, not a technicality: a review
    # whose inline comments GitHub would not hand over might carry an unmarked
    # one, and this must never guess in that direction.
    def agent_reply_reason(event)
      if event.commented? && event.reviewed_by?(@operator) && event.comments_complete? && event.agent_authored?
        "commented by the operator (#{@operator}) with every line #{BasecampAgentConnector::GitHub::ReviewEvent::AGENT_PREFIX}-marked — " \
          "the dispatched agent's own reply, not a person's"
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

    def log_dropped(event, reason)
      log "dropped review #{event.id}: #{reason}"
    end

    def log(message)
      @logger.puts message
    end
end
