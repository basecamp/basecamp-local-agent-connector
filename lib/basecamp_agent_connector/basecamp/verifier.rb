class BasecampAgentConnector::Basecamp::Verifier
  def initialize(basecamp_cli:, agent:)
    @basecamp_cli = basecamp_cli
    @agent = agent
  end

  def verify(event)
    recording = fetch_recording(event)

    if corroborated?(recording, event)
      authoritative_event(event, recording)
    end
  end

  private
    # Chat lines don't resolve through the generic recordings endpoint `show`
    # uses (bc3 keeps chat out of it), so corroborate them through the chat
    # line endpoint instead. Corroborating a polled line the poller itself just
    # fetched is not redundant: it keeps chat on the identical trust path as
    # webhook kinds, and re-reads the line at dispatch time so one deleted (or
    # edited away from the mention) between poll and processing is dropped.
    def fetch_recording(event)
      locator = event.recording_url || event.recording_app_url
      return nil if locator.nil?

      if event.chat_kind?
        @basecamp_cli.chat_line(locator)
      else
        @basecamp_cli.show(locator)
      end
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

    def authoritative_event(event, recording)
      BasecampAgentConnector::Basecamp::Event.from_payload \
        "id" => event.id,
        "kind" => event.kind,
        "created_at" => event.created_at,
        "details" => event.details,
        "creator" => event.assignment_changed? ? event.creator : recording.fetch("creator"),
        "recording" => recording
    end
end
