class BasecampAgentConnector::Basecamp::Pipeline
  def initialize(authorizer:, agent:, verifier:, emitter:, logger: $stderr)
    @authorizer = authorizer
    @agent = agent
    @verifier = verifier
    @emitter = emitter
    @logger = logger
    @seen_event_ids = Set.new
  end

  def process(payload)
    event = BasecampAgentConnector::Basecamp::Event.from_payload(payload)

    if actionable?(event) && fresh?(event)
      emit_if_verified(event)
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
    # For an assignment the verifier corroborates the agent's live assignee
    # state but keeps the claimed assigner, so this re-check re-tests that same
    # claimed identity (the verifier, not this method, is what proves the
    # assignment real).
    def emit_if_verified(event)
      verified = @verifier.verify(event)

      if verified.nil?
        log "dropped event #{event.id}: not corroborated by Basecamp"
      elsif !@authorizer.authorizes?(verified)
        log "dropped event #{event.id}: authoritative author is not authorized"
      elsif !targets_agent?(verified)
        log "dropped event #{event.id}: authoritative recording does not target the agent"
      else
        @emitter.emit(verified)
      end
    end

    def log(message)
      @logger.puts message
    end
end
