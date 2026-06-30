class BasecampAgentConnector::Basecamp::Verifier
  def initialize(basecamp_cli:)
    @basecamp_cli = basecamp_cli
  end

  def verify(event)
    recording = fetch_recording(event)

    if corroborated?(recording, event)
      authoritative_event(event, recording)
    end
  end

  private
    def fetch_recording(event)
      locator = event.recording_url || event.recording_app_url
      return nil if locator.nil?

      @basecamp_cli.show(locator)
    rescue BasecampAgentConnector::Basecamp::Client::Error
      nil
    end

    def corroborated?(recording, event)
      recording.is_a?(Hash) && recording.dig("creator", "id") == event.creator_id
    end

    def authoritative_event(event, recording)
      BasecampAgentConnector::Basecamp::Event.from_payload \
        "id" => event.id,
        "kind" => event.kind,
        "created_at" => event.created_at,
        "creator" => recording.fetch("creator"),
        "recording" => recording
    end
end
