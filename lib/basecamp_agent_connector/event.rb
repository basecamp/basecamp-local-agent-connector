class BasecampAgentConnector::Event
  ACTIONABLE_KIND_SUFFIXES = [ "_created", "_content_changed" ]

  MENTION_CONTENT_TYPE = "application/vnd.basecamp.mention"

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

  def creator_email
    creator["email_address"]
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
    return false if creator_email.nil? || identity.email.nil?

    creator_email.casecmp?(identity.email)
  end

  def mentions?(agent)
    return false if agent.name.nil?

    # Basecamp renders the mention avatar's alt as the full display name
    # ("Marie Chef (Agent)"), while agent.name is the first name ("Marie"), so
    # match the name as the leading token of alt rather than the whole value.
    body = content.to_s
    body.include?(MENTION_CONTENT_TYPE) && body.match?(/<img[^>]*\balt="#{Regexp.escape(agent.name)}(?: |")/i)
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
end
