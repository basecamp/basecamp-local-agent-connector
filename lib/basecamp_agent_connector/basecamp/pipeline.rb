class BasecampAgentConnector::Basecamp::Pipeline
  def initialize(operator:, agent:, verifier:, emitter:, watched_columns: [], logger: $stderr)
    @operator = operator
    @agent = agent
    @verifier = verifier
    @emitter = emitter
    @watched_columns = watched_columns
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
    # Two ways in. The operator triggers one by authoring the event and pointing it
    # at the agent; a watched column triggers the other on card creation alone,
    # with no operator involvement at all. Both still pass verification.
    def actionable?(event)
      event.actionable_kind? && (operator_triggered?(event) || watched_creation?(event))
    end

    def operator_triggered?(event)
      event.authored_by?(@operator) && targets_agent?(event)
    end

    def watched_creation?(event)
      @watched_columns.any? { |watched| watched.matches?(event) }
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
