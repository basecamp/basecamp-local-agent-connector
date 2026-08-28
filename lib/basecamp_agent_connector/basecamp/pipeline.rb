class BasecampAgentConnector::Basecamp::Pipeline
  def initialize(authorizer:, agent:, verifier:, emitter:, logger: $stderr)
    @authorizer = authorizer
    @agent = agent
    @verifier = verifier
    @emitter = emitter
    @logger = logger
    @seen_event_ids = Set.new
    @verdict = Mutex.new
  end

  # Returns whether the event reached a verdict (emitted, dropped, ignored,
  # or a duplicate). False means Basecamp did not corroborate it — the
  # recording is gone, or never existed — in which case the id is forgotten
  # so a redelivery gets a fresh attempt, since re-verifying is idempotent.
  # When Basecamp could not be asked at all (Client::TransientError, after
  # the client's own retries) that error propagates with the id likewise
  # forgotten: the caller decides how to defer — a webhook answers 503 so
  # Basecamp redelivers, a poller retries on its next tick — and must not
  # record a verdict, because there is none.
  #
  # One delivery at a time, so that "seen" always means settled. Deliveries
  # arrive on concurrent server threads, and a verification that overruns
  # bc3's 10s delivery timeout is redelivered while the original is still in
  # flight; unserialized, the redelivery would find the id seen, be answered
  # 200 as a duplicate, and then the original could fail and forget the id —
  # with nobody left to redeliver. Held here, the redelivery waits and finds
  # either a settled id (a duplicate) or a forgotten one (a fresh attempt).
  # The pollers each own a pipeline and poll from a single thread, so they
  # never wait on this.
  def process(payload)
    event = BasecampAgentConnector::Basecamp::Event.from_payload(payload)

    @verdict.synchronize do
      if actionable?(event) && fresh?(event)
        emit_if_verified(event)
      else
        true
      end
    end
  end

  private
    def actionable?(event)
      event.actionable_kind? && @authorizer.authorizes?(event) && worth_verifying?(event)
    end

    # The pre-filter is deliberately looser than the authoritative target check:
    # a comment carries no subscription flag in its payload, so it can't prove it
    # targets the agent until the Verifier re-fetches subscribers — and a boost
    # can't prove it landed on the agent's work until the Verifier re-fetches the
    # agent's own received-boosts feed. Admit both here (author is already gated)
    # so the live fact can be corroborated; `targets_agent?` on the verified
    # event makes the real decision.
    def worth_verifying?(event)
      targets_agent?(event) || event.subscribable_comment? || event.boost?
    end

    def targets_agent?(event)
      event.mentions?(@agent) || event.assigns?(@agent) || event.subscribed? || event.boosted?
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
    # the claimed assigner is who performed the assignment). For a comment on a
    # subscribed recording there is no mention to re-check; the verifier stamps
    # the subscription it confirmed against the live subscribers API, and
    # `targets_agent?` reads only that stamp — so a comment the agent doesn't
    # actually subscribe to is dropped here too. A boost works the same way:
    # the verifier stamps `agent_boosted` only after finding the boost in a
    # fresh fetch of the agent's own received-boosts feed, with the emitted
    # booster and content taken from that fetch.
    def emit_if_verified(event)
      verified = @verifier.verify(event)

      if verified.nil?
        @seen_event_ids.delete(event.id)
        log "dropped event #{event.id}: not corroborated by Basecamp (id forgotten; a later delivery of it is verified afresh)"
      elsif !@authorizer.authorizes?(verified)
        log "dropped event #{event.id}: authoritative author is not authorized"
      elsif !targets_agent?(verified)
        log "dropped event #{event.id}: authoritative recording does not target the agent"
      else
        @emitter.emit(verified)
      end

      !verified.nil?
    rescue BasecampAgentConnector::Basecamp::Client::TransientError
      @seen_event_ids.delete(event.id)
      raise
    end

    def log(message)
      @logger.puts message
    end
end
