class BasecampAgentConnector::Basecamp::Verifier
  COMMENT_RECORDING_TYPE = "Comment"

  def initialize(basecamp_cli:, agent:)
    @basecamp_cli = basecamp_cli
    @agent = agent
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
    def fetch_recording(event)
      locator = event.recording_url || event.recording_app_url
      return nil if locator.nil?

      if event.chat_kind?
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

      if event.assignment_changed?
        assigns_agent?(recording)
      else
        recording.dig("creator", "id") == event.creator_id
      end
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
        "agent_subscribed" => agent_subscribed?(event, recording, mentioned: mentioned)
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
