class BasecampAgentConnector::Event
  ACTIONABLE_KIND_SUFFIXES = ["_created", "_content_changed"]

  EMITTED_RECORDING_FIELDS = %w[id type title app_url url content parent bucket]
  EMITTED_CREATOR_FIELDS = %w[id name email_address]

  def self.from_payload(payload)
    new(payload)
  end

  def initialize(payload)
    @payload = payload
  end

  def id
    @payload["id"]
  end

  def kind
    @payload["kind"].to_s
  end

  def created_at
    @payload["created_at"]
  end

  def creator
    @payload["creator"] || {}
  end

  def creator_id
    creator["id"]
  end

  def recording
    @payload["recording"] || {}
  end

  def recording_url
    recording["url"]
  end

  def recording_app_url
    recording["app_url"]
  end

  def content
    recording["content"]
  end

  def actionable_kind?
    kind.end_with?(*ACTIONABLE_KIND_SUFFIXES)
  end

  def authored_by?(identity)
    !creator_id.nil? && creator_id == identity.id
  end

  def mentions?(trigger)
    text = stripped_content
    !text.empty? && text.match?(trigger_pattern(trigger))
  end

  def to_emitted_hash
    {
      "event_id" => id,
      "kind" => kind,
      "created_at" => created_at,
      "creator" => creator.slice(*EMITTED_CREATOR_FIELDS),
      "recording" => recording.slice(*EMITTED_RECORDING_FIELDS)
    }
  end

  private
    def stripped_content
      content.to_s.gsub(/<[^>]+>/, " ")
    end

    def trigger_pattern(trigger)
      /#{Regexp.escape(trigger)}(?!\w)/i
    end
end
