class BasecampAgentConnector::Basecamp::Pipeline
  def initialize(operator:, agent:, verifier:, emitter:, logger: $stderr)
    @operator = operator
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
      event.actionable_kind? && event.authored_by?(@operator) && targets_agent?(event)
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

    def emit_if_verified(event)
      verified = @verifier.verify(event)

      if verified
        @emitter.emit(verified)
      else
        log "dropped event #{event.id}: not corroborated by Basecamp"
      end
    end

    def log(message)
      @logger.puts message
    end
end
