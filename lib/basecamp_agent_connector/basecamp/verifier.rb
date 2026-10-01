class BasecampAgentConnector::Basecamp::Verifier
  COMMENT_RECORDING_TYPE = "Comment"

  # A recording Basecamp still files as a draft is visible to nobody but its
  # author, and bc3 relays no event for one ("don't leak drafts": Webhook's
  # `eligible_event?`). So a delivery naming one is either a forgery or a
  # recording re-drafted since the event, and either way it stays private.
  DRAFTED_STATUS = "drafted"

  # `operator` is needed for one thing: deciding whether a Ping is private to
  # the agent and the person allowed to direct it. See private_ping?.
  def initialize(basecamp_cli:, agent:, operator: nil)
    @basecamp_cli = basecamp_cli
    @agent = agent
    @operator = operator
  end

  def verify(event)
    if event.boost?
      verify_boost(event)
    else
      recording = fetch_recording(event)

      if corroborated?(recording, event)
        authoritative_event(event, recording)
      end
    end
  end

  private
    # Chat lines don't resolve through the generic recordings endpoint `show`
    # uses (bc3 keeps chat out of it), so corroborate them through the chat
    # line endpoint instead. Corroborating a polled line the poller itself just
    # fetched is not redundant: it keeps chat on the identical trust path as
    # webhook kinds, and re-reads the line at dispatch time so one deleted (or
    # edited away from the mention) between poll and processing is dropped.
    #
    # Only Basecamp's own refusal (not found, forbidden) means "no such
    # recording". A fetch the CLI could not complete even after its retries
    # says nothing about the recording, so it propagates for the caller to
    # defer — a webhook answers 503 for redelivery, a poller retries next
    # tick — instead of masquerading as a forged or deleted event.
    # A ping line takes a third route again. `chat line` resolves its
    # `--project` through `/projects/<id>.json` and a Circle is not a project,
    # so it 404s on every ping (verified against production); and the fetch
    # has to run **as the agent** in any case, because Basecamp serves a
    # Circle to nobody but the people in it. That refusal is load-bearing
    # rather than incidental: a line the agent is served is a line in a room
    # the agent is in.
    def fetch_recording(event)
      locator = event.recording_url || event.recording_app_url
      return nil if locator.nil?

      if event.ping?
        @basecamp_cli.get(locator, profile: @agent.profile)
      elsif event.chat_kind?
        @basecamp_cli.chat_line(locator)
      else
        @basecamp_cli.show(locator)
      end
    rescue BasecampAgentConnector::Basecamp::Client::TransientError
      raise
    rescue BasecampAgentConnector::Basecamp::Client::Error
      nil
    end

    # For a mention/comment the authoritative author is the recording's creator,
    # so confirm it matches the claimed event author. For an assignment the event
    # author is the assigner (not the recording's creator), so instead confirm the
    # agent is actually among the recording's current assignees — a forged POST
    # can't fake real Basecamp state.
    def corroborated?(recording, event)
      return false unless recording.is_a?(Hash)
      return false if drafted?(recording)

      if event.assignment_changed?
        assigns_agent?(recording)
      elsif event.ping?
        recording.dig("creator", "id") == event.creator_id && in_a_circle?(recording)
      else
        recording.dig("creator", "id") == event.creator_id
      end
    end

    # Read off the *re-fetched* line, never off the claimed payload: the kind
    # said this was a ping, and this is Basecamp agreeing. Without it a
    # ping-shaped payload naming a project Campfire line would be dispatched
    # on room membership alone, skipping the mention a Campfire line owes.
    def in_a_circle?(recording)
      recording.dig("bucket", "type") == BasecampAgentConnector::Basecamp::Event::CIRCLE_BUCKET_TYPE
    end

    # Only what Basecamp positively marks a draft is refused: representations
    # that carry no status at all (a chat line) say nothing about drafting, and
    # nothing in bc3 can draft them.
    def drafted?(recording)
      recording["status"] == DRAFTED_STATUS
    end

    def assigns_agent?(recording)
      return false if @agent.person_id.nil?

      assignee_ids(recording).include?(@agent.person_id)
    end

    def assignee_ids(recording)
      Array(recording["assignees"]).map { |assignee| assignee["id"] }
    end

    # Both trigger verdicts are settled on the re-fetched recording — the same
    # authoritative content the pipeline's `targets_agent?` re-check reads — so
    # the stamps the watcher reads off the emitted line cannot disagree with
    # the drop decision. The pipeline still runs `Event#mentions?` itself; the
    # `agent_mentioned` stamp exists for the emitted line, not for the gate.
    def authoritative_event(event, recording)
      mentioned = mentions_agent?(recording)

      BasecampAgentConnector::Basecamp::Event.from_payload \
        "id" => event.id,
        "kind" => event.kind,
        "created_at" => event.created_at,
        "details" => event.details,
        "creator" => event.assignment_changed? ? event.creator : recording.fetch("creator"),
        "recording" => recording,
        "agent_mentioned" => mentioned,
        "agent_subscribed" => agent_subscribed?(event, recording, mentioned: mentioned),
        "agent_pinged" => agent_pinged?(event, recording)
    end

    # The check a mention makes on every other surface, made here instead. A
    # ping is actionable because the conversation is the agent's and its
    # operator's and nobody else's — so that has to come from Basecamp rather
    # than from the payload. A third participant makes it someone else's
    # conversation too, and the reply the agent posts lands in front of them.
    #
    # Re-read per event rather than remembered with the room, because a Ping
    # that gains a participant has to stop triggering from that moment, and a
    # remembered verdict would go on answering for the old membership.
    #
    # Only the operator is recognized, in every trust mode. The broadened
    # modes key on an author's email or client flag, and bc3 redacts other
    # people's addresses from a non-admin reader — the agent reading this
    # subscription sees `y•••••••@•••••••.•••` — so there is nothing here for
    # them to match on. Failing closed means a Ping with a third person in it
    # never triggers, whatever `--trust` says; widening that needs a
    # person-level trust test Basecamp does not currently give the agent the
    # fields for.
    def agent_pinged?(event, recording)
      event.ping? && private_ping?(recording)
    end

    def private_ping?(recording)
      return false if @operator.nil? || @operator.person_id.nil? || @agent.person_id.nil?

      ping_subscriber_ids(recording).sort == [ @operator.person_id, @agent.person_id ].sort
    end

    # A Circle's subscription is served only to the people in the room, so
    # this runs as the agent. `subscriptions show` takes no profile and would
    # ask as the operator — which for a Ping the operator is not in would
    # answer about the wrong room, or not at all.
    def ping_subscriber_ids(recording)
      locator = ping_subscription_path(recording)
      return [] if locator.nil?

      Array(@basecamp_cli.get(locator, profile: @agent.profile)["subscribers"]).map { |subscriber| subscriber["id"] }
    rescue BasecampAgentConnector::Basecamp::Client::TransientError
      raise
    rescue BasecampAgentConnector::Basecamp::Client::Error
      []
    end

    # Built from the authoritative line's own ids: its Circle, and the
    # transcript it hangs off. A chat line's subscription lives on the
    # transcript, not the line.
    def ping_subscription_path(recording)
      circle = recording.dig("bucket", "id")
      transcript = recording.dig("parent", "id")

      "/buckets/#{circle}/recordings/#{transcript}/subscription.json" unless circle.nil? || transcript.nil?
    end

    # A comment can trigger by subscription instead of by a mention: confirm,
    # against the live subscribers API, that the agent subscribes to the
    # comment's parent (the commented-on recording — subscriptions live on the
    # container, not the comment). This is the connector's own re-fetch, so the
    # stamp binds to what Basecamp reports now, not to anything in the POST. A
    # refused or missing lookup stamps false: never emit on an unconfirmed
    # subscription. A lookup the CLI could not complete propagates instead
    # (see fetch_recording): stamping false would turn a transient failure
    # into a settled "does not target the agent" drop.
    #
    # The recording's authoritative `type` must be a Comment, not just the
    # claimed `comment_created` kind: otherwise a forged POST naming that kind
    # but pointing at an existing subscribed Message/Card would corroborate on
    # creator and pass the subscriber check, emitting though no comment exists.
    def agent_subscribed?(event, recording, mentioned:)
      event.subscribable_comment? && \
        recording["type"] == COMMENT_RECORDING_TYPE && \
        !mentioned && \
        agent_subscribes_to_parent?(recording)
    end

    # A mention triggers on its own, so a mentioning comment needs no subscribers
    # lookup. Reuse the canonical mention matcher on the authoritative recording.
    def mentions_agent?(recording)
      BasecampAgentConnector::Basecamp::Event.from_payload("recording" => recording).mentions?(@agent)
    end

    def agent_subscribes_to_parent?(recording)
      locator = subscription_locator(recording)

      if @agent.person_id.nil? || locator.nil?
        false
      else
        subscriber_ids(locator).include?(@agent.person_id)
      end
    end

    def subscription_locator(recording)
      parent = recording["parent"] || {}
      parent["url"] || parent["app_url"] || recording["url"] || recording["app_url"]
    end

    def subscriber_ids(locator)
      Array(@basecamp_cli.subscription(locator)["subscribers"]).map { |subscriber| subscriber["id"] }
    rescue BasecampAgentConnector::Basecamp::Client::TransientError
      raise
    rescue BasecampAgentConnector::Basecamp::Client::Error
      []
    end

    # A boost has no recording endpoint to re-fetch — it is not a Recording.
    # The one place Basecamp reports it is the boostee's own received-boosts
    # feed, so corroborate against a fresh fetch of the agent's feed: the
    # claimed boost id must be present with the claimed booster. Everything
    # emitted — booster, content, boosted recording — comes from that fresh
    # fetch, so a payload contributes nothing but the id to look up. Presence
    # in the agent's own feed is also the targeting fact (the feed files a
    # boost under the person it was aimed at), stamped as `agent_boosted` for
    # the pipeline's authoritative target re-check. A boost deleted — or
    # scrolled off the feed's newest-page window — between poll and dispatch
    # stops being corroborable and is dropped, exactly like a deleted comment.
    # A feed fetch the CLI could not complete propagates, exactly like a
    # recording fetch (see fetch_recording), so the poller retries it.
    def verify_boost(event)
      boost = fetch_boost(event)

      if !boost.nil? && boost.dig("booster", "id") == event.creator_id
        authoritative_boost_event(event, boost)
      end
    end

    def fetch_boost(event)
      return nil if @agent.profile.nil?

      @basecamp_cli.received_boosts(profile: @agent.profile).find { |boost| boost["id"] == event.id }
    rescue BasecampAgentConnector::Basecamp::Client::TransientError
      raise
    rescue BasecampAgentConnector::Basecamp::Client::Error
      nil
    end

    def authoritative_boost_event(event, boost)
      BasecampAgentConnector::Basecamp::Event.from_payload \
        "id" => event.id,
        "kind" => event.kind,
        "created_at" => boost["created_at"],
        "details" => { "boost" => boost.slice("id", "content") },
        "creator" => boost["booster"],
        "recording" => boost["recording"] || {},
        "agent_boosted" => true
    end
end
