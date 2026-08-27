class BasecampAgentConnector::Basecamp::Pipeline
  def initialize(authorizer:, agent:, verifier:, emitter:, logger: $stderr)
    @authorizer = authorizer
    @agent = agent
    @verifier = verifier
    @emitter = emitter
    @logger = logger
    @seen_event_ids = Set.new
  end

  # Returns whether the event reached a verdict (emitted, dropped, ignored,
  # or a duplicate). False means Basecamp could not corroborate it, in which
  # case the id is forgotten so a redelivery gets a fresh attempt: the fetch
  # may have failed transiently, and re-verifying is idempotent either way.
  def process(payload)
    event = BasecampAgentConnector::Basecamp::Event.from_payload(payload)

    if actionable?(event) && fresh?(event)
      emit_if_verified(event)
    else
      true
    end
  end

  private
    def actionable?(event)
      event.actionable_kind? && @authorizer.authorizes?(event) && targets_agent?(event)
    end

    def targets_agent?(event)
      event.mentions?(@agent) || event.assigns?(@agent)
    end

    def fresh?(event)
      if @seen_event_ids.include?(event.id)
        false
      else
        @seen_event_ids << event.id
        true
      end
    end

    # Both trust predicates are re-checked on the verified event, not just the
    # claimed payload. For a mention, corroboration replaces the pre-filter's
    # forgeable POST fields with what Basecamp actually recorded — the
    # recording's real creator and its real content — so it is the authoritative
    # author who must be authorized and the authoritative recording that must
    # target the agent; a forged payload pairing a fake mention with a real
    # recording the agent was never mentioned in is dropped here, not emitted.
    # For an assignment the verifier corroborates the agent's current assignee
    # state but keeps the claimed assigner, so this re-check re-tests that same
    # claimed identity (the verifier confirms the live assignee state, not that
    # the claimed assigner is who performed the assignment).
    def emit_if_verified(event)
      verified = @verifier.verify(event)

      if verified.nil?
        @seen_event_ids.delete(event.id)
        log "dropped event #{event.id}: not corroborated by Basecamp (retried if delivered again)"
      elsif !@authorizer.authorizes?(verified)
        log "dropped event #{event.id}: authoritative author is not authorized"
      elsif !targets_agent?(verified)
        log "dropped event #{event.id}: authoritative recording does not target the agent"
      else
        @emitter.emit(verified)
      end

      !verified.nil?
    end

    def log(message)
      @logger.puts message
    end
end
