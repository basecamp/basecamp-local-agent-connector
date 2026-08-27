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

  def initialize(basecamp_cli:, agent:, operator: nil)
    @basecamp_cli = basecamp_cli
    @agent = agent
    @operator = operator
  end

  def verify(event)
    recording = fetch_recording(event)

    if corroborated?(recording, event)
      authoritative_event(event, recording)
    end
  end

  private
    # A ping line is read through the raw API and every other recording through
    # `show`, because `show` cannot fetch one: it rewrites the line's own URL to
    # `recordings/<id>.json`, which resolves to nothing, and a chat line only
    # answers under its transcript.
    def fetch_recording(event)
      locator = event.recording_url || event.recording_app_url
      return nil if locator.nil?

      if event.ping?
        @basecamp_cli.get(locator, profile: @agent.profile)
      else
        @basecamp_cli.show(locator, profile: @agent.profile)
      end
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
      elsif event.ping?
        recording.dig("creator", "id") == event.creator_id && private_to_the_two_of_them?(event)
      else
        recording.dig("creator", "id") == event.creator_id
      end
    end

    # The check a mention makes on every other surface, made here instead. A ping
    # is actionable because the conversation is the operator's and the agent's and
    # nobody else's, so that has to be established from Basecamp rather than from
    # the payload -- a third participant makes it someone else's conversation too,
    # and the reply the agent would post lands in front of them.
    #
    # Re-read every time rather than remembered with the circle, because a circle
    # that gains a participant must stop triggering from that moment, and a
    # remembered verdict would go on answering for the old membership.
    def private_to_the_two_of_them?(event)
      return false if @operator.nil? || @operator.person_id.nil? || @agent.person_id.nil?

      subscriber_ids(event).sort == [ @operator.person_id, @agent.person_id ].sort
    end

    def subscriber_ids(event)
      circle = BasecampAgentConnector::Basecamp::Circle.new(id: event.bucket_id, transcript: event.transcript_id)
      subscription = @basecamp_cli.get(circle.subscription_path, profile: @agent.profile)

      Array(subscription.is_a?(Hash) ? subscription["subscribers"] : nil).map { |subscriber| subscriber["id"] }
    rescue BasecampAgentConnector::Basecamp::Client::Error => error
      raise Unreachable, "could not read the participants of #{circle}: #{error.message}" if UNREACHABLE.match?(error.message)

      []
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
