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
    # Three ways in. The operator triggers one by authoring the event and pointing
    # it at the agent; a watched column triggers the other on card creation alone,
    # with no operator involvement at all; a ping triggers the third by being a
    # conversation he opened with the agent and nobody else. All three still pass
    # verification.
    def actionable?(event)
      event.actionable_kind? &&
        (operator_triggered?(event) || watched_creation?(event) || ping_from_operator?(event))
    end

    # A ping carries no mention and needs none. Asking for one would mean asking
    # him to @mention the agent in a two-person conversation with it, which is
    # what the conversation already is. What stands in its place is the Verifier's
    # subscriber check: a circle whose participants are anyone besides the two of
    # them is not this trigger.
    def ping_from_operator?(event)
      event.ping? && event.authored_by?(@operator)
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
