class BasecampAgentConnector::Basecamp::Verifier
  # Raised when the corroborating read could not be made at all. A forged event
  # and an unreachable API both used to return nil here, so a transient failure
  # was silently indistinguishable from a rejection -- and the caller had already
  # written the event off as handled.
  Unreachable = Class.new(StandardError)

  # Deliberately narrow, and matched on the message because Client::Error carries
  # nothing else. A 404 is not in here: the recording really is absent, which is a
  # rejection and stays one. These are the failures that mean the question was
  # never asked -- the profile's credentials read as missing while the token is
  # valid for another fortnight, or the network dropped underneath the call.
  # Spaces are written `\s` because `/x` discards literal whitespace: every
  # multi-word phrase here was dead from the day it was written, and only the one
  # single-word alternative and the status codes ever matched. What that cost is
  # exactly what this class exists to prevent -- a lost credential race read as a
  # forgery, dropped, and recorded as handled.
  UNREACHABLE = /not\sauthenticated|credentials\snot\sfound|no\ssuch\sprofile|
                 timed\sout|timeout|connection\s(refused|reset)|could\snot\sconnect|
                 network\sis\s(down|unreachable)|temporarily\sunavailable|
                 \b(429|500|502|503|504)\b/xi

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
    def fetch_recording(event)
      locator = event.recording_url || event.recording_app_url
      return nil if locator.nil?

      @basecamp_cli.show(locator, profile: @agent.profile)
    rescue BasecampAgentConnector::Basecamp::Client::Error => error
      raise Unreachable, "could not corroborate #{locator}: #{error.message}" if UNREACHABLE.match?(error.message)

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
