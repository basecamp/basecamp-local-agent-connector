class BasecampAgentConnector::Basecamp::Pipeline
  def initialize(authorizer:, agent:, verifier:, emitter:, webhook: false, logger: $stderr)
    @authorizer = authorizer
    @agent = agent
    @verifier = verifier
    @emitter = emitter
    @webhook = webhook
    @logger = logger
    @seen_event_ids = Set.new
    @in_flight_event_ids = Set.new
    @lock = Mutex.new
    @settled = ConditionVariable.new
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
  # Verdicts are per event id, so that "seen" always means settled: an id is
  # claimed while its verification is in flight and stays seen once it
  # settled. Deliveries arrive on concurrent server threads, and a
  # verification that overruns bc3's 10s delivery timeout is redelivered
  # while the original is still in flight; unsynchronized, the redelivery
  # would find the id seen, be answered 200 as a duplicate, and then the
  # original could fail and forget the id — with nobody left to redeliver.
  # So a delivery of an id in flight waits for that id's verdict (see
  # `claim`) and finds either a settled id (a duplicate) or a forgotten one
  # (a fresh attempt). Distinct ids never wait on each other: each
  # verification shells out to the CLI, and a burst serialized behind one
  # slow verification would time out delivery after delivery. The pollers
  # each own a pipeline and poll from a single thread, so they never wait.
  def process(payload)
    event = BasecampAgentConnector::Basecamp::Event.from_payload(payload)

    if impostor_on_webhook?(event)
      true
    elsif actionable?(event) && claim(event)
      begin
        emit_if_verified(event)
      ensure
        release(event.id)
      end
    else
      true
    end
  end

  # Whether this pipeline has heard of an event id: reached a verdict on it
  # that it still remembers — emitted, or dropped on the authoritative
  # re-check. An id it forgot (Basecamp would not corroborate it, or could not
  # be asked) has not been heard, and neither has one the pre-filter turned
  # away before claiming it. The DeliveryReconciler asks, so that a failed
  # delivery of an event that did arrive by another delivery is neither
  # replayed nor reported as a hole.
  #
  # An id still being verified has no verdict yet, so this waits for that
  # verification to settle, as `claim` does, and answers on the outcome. A
  # snapshot taken mid-verification would call heard an event whose
  # verification is about to find no verdict and be forgotten — answered 503,
  # perhaps, on a connection bc3 already gave up on — and whoever trusted that
  # answer would let the trigger go with nobody left to recover it.
  def heard?(event_id)
    @lock.synchronize { heard_once_settled?(event_id) }
  end

  # Runs the block unless the event id is heard, decided as `heard?` decides
  # it, with no delivery of that id able to settle between the answer and what
  # the block does about it. That is not done by holding the lock across the
  # block: the block writes a log line, and a stderr nobody is draining would
  # then stall every live delivery's claim and release, unrelated events on
  # every project included. It is done by holding the id itself in flight for
  # the block's duration, so only a delivery of that same event waits, and it
  # waits for the block exactly as it would for a verification. The
  # reservation marks nothing seen: once the block is done, that delivery
  # claims the id afresh. Answers whether the block ran.
  def unless_heard(event_id)
    reserved = @lock.synchronize do
      if heard_once_settled?(event_id)
        false
      else
        @in_flight_event_ids << event_id
        true
      end
    end

    if reserved
      begin
        yield
      ensure
        release(event_id)
      end

      true
    end
  end

  private
    # Basecamp never delivers chat or boost events by webhook: bc3
    # hard-excludes every chat kind from relay, and a boost is not a Recording
    # and creates no event. A ping needs no clause of its own: it is a chat
    # line, so it is refused here with the rest of them — and it has to be,
    # since a ping is the one payload that could claim to target the agent
    # with no mention in it at all. So on the webhook pipeline either kind is
    # by definition not from Basecamp, and is refused rather than corroborated —
    # or let replay a real boost past the BoostPoller's own dedupe, which this
    # pipeline does not share. The refusal lives here rather than on the route
    # so that every way into the webhook pipeline passes it: a live delivery
    # and a reconciled one alike.
    def impostor_on_webhook?(event)
      if @webhook && event.chat_kind?
        log "ignored chat-kind payload: Basecamp does not deliver chat webhooks"
        true
      elsif @webhook && event.boost?
        log "ignored boost-kind payload: Basecamp does not deliver boost webhooks"
        true
      else
        false
      end
    end

    # Called under the lock.
    def heard_once_settled?(event_id)
      @settled.wait(@lock) while @in_flight_event_ids.include?(event_id)
      @seen_event_ids.include?(event_id)
    end

    def actionable?(event)
      event.actionable_kind? && @authorizer.authorizes?(event) && worth_verifying?(event)
    end

    # The pre-filter is deliberately looser than the authoritative target check:
    # a comment carries no subscription flag in its payload, so it can't prove it
    # targets the agent until the Verifier re-fetches subscribers — a boost
    # can't prove it landed on the agent's work until the Verifier re-fetches the
    # agent's own received-boosts feed — and a ping line carries no mention at
    # all, because being in the room is the addressing, which only a read of
    # the Circle's own subscription settles. Admit all three here (author is
    # already gated) so the live fact can be corroborated; `targets_agent?` on
    # the verified event makes the real decision.
    def worth_verifying?(event)
      targets_agent?(event) || event.subscribable_comment? || event.boost? || event.ping?
    end

    def targets_agent?(event)
      event.mentions?(@agent) || event.assigns?(@agent) || event.subscribed? || event.boosted? || event.pinged?
    end

    # The in-flight set plus one condition variable is the whole mechanism:
    # the lock is held only to read and update the two sets, never across a
    # verification, and every settled verification broadcasts so a waiter
    # re-checks its own id (a wake-up for someone else's id just loops).
    def claim(event)
      @lock.synchronize do
        @settled.wait(@lock) while @in_flight_event_ids.include?(event.id)

        if @seen_event_ids.include?(event.id)
          false
        else
          @seen_event_ids << event.id
          @in_flight_event_ids << event.id
          true
        end
      end
    end

    def release(event_id)
      @lock.synchronize do
        @in_flight_event_ids.delete(event_id)
        @settled.broadcast
      end
    end

    def forget(event)
      @lock.synchronize { @seen_event_ids.delete(event.id) }
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
    # booster and content taken from that fetch. A ping is the same shape
    # again: the verifier stamps `agent_pinged` only after the re-fetched line
    # says its bucket really is a Circle and a fresh read of that Circle's
    # subscription says the room holds the agent and its operator and nobody
    # else — so a Campfire line can never be dispatched on room membership in
    # place of the mention it owes, and a Ping that has gained a third person
    # stops triggering from that moment.
    def emit_if_verified(event)
      verified = @verifier.verify(event)

      if verified.nil?
        forget(event)
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
      forget(event)
      raise
    end

    def log(message)
      @logger.puts message
    end
end
