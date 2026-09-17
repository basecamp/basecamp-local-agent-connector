require "json"

# Turns one signed `pull_request_review` delivery into one emitted review:
# verify the HMAC, filter, dedup, re-fetch the review from the API, emit.
#
# Which reviewer/state pairs travel is `drop_reason`'s single decision — the
# trust boundary (only the operator's approvals) and the self-review drop
# (never the operator's own bare comments) both live there. That gate runs
# twice: on the claimed delivery as a cheap pre-filter, and again on the
# verified review so the decision binds to the reviewer GitHub actually
# recorded, not to the delivery body.
class BasecampAgentConnector::GitHub::ReviewPipeline
  def initialize(secret:, operator:, verifier:, emitter:, include_self_reviews: false, logger: $stderr)
    @secret = secret
    @operator = operator
    @verifier = verifier
    @emitter = emitter
    @include_self_reviews = include_self_reviews
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
      if (reason = drop_reason(event))
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

    # The one place a review's reviewer and state decide whether it travels:
    # nil to let it through, otherwise the reason it is dropped, which is also
    # what STDERR says.
    #
    # Approvals are the trust boundary: an emitted `approved` review is what
    # lets the dispatched agent land the PR, so only the operator's approvals
    # pass.
    #
    # A bare `commented` review by the operator is the mirror case, and it is
    # noise rather than trust: the dispatched agent commits and comments on
    # GitHub under the operator's own account, so a comment review from that
    # login is, in practice, the agent answering a review thread on its own PR
    # — emitting it wakes a session to read itself talking, which was most of
    # the events in a real day of running this. The operator's *approval* is
    # kept regardless, because it is the signal the whole loop rests on and
    # dropping it would strand every PR waiting to land; so is the operator's
    # `changes_requested`, which asks for work no matter who typed it. Every
    # other reviewer passes in every state, Copilot included.
    def drop_reason(event)
      if event.approved? && !event.reviewed_by?(@operator)
        "approved by #{event.reviewer.inspect}, not by the operator (#{@operator})"
      elsif self_comment?(event)
        "commented by the operator (#{@operator}) — the dispatched agent reviews as the operator, " \
          "so this is the agent talking to itself; pass --include-self-reviews to emit these"
      end
    end

    def self_comment?(event)
      !@include_self_reviews && event.commented? && event.reviewed_by?(@operator)
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
      elsif (reason = drop_reason(verified))
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
