require "base64"

class BasecampAgentConnector::Event
  ACTIONABLE_KIND_SUFFIXES = [ "_created", "_content_changed" ]

  MENTION_CONTENT_TYPE = "application/vnd.basecamp.mention"

  # The webhook delivers a mention as an unexpanded attachment carrying only an
  # SGID and content-type — no rendered name. The agent's account-scoped Person
  # id is encoded inside the SGID, so match on that id rather than a display name.
  MENTION_ATTACHMENT = /<bc-attachment\b[^>]*content-type="#{Regexp.escape(MENTION_CONTENT_TYPE)}"[^>]*>/i

  PERSON_GID = %r{gid://bc3/Person/(\d+)}

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
    return false if agent.person_id.nil?

    mentioned_person_ids.include?(agent.person_id)
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
    def mentioned_person_ids
      mention_attachment_sgids.flat_map { |sgid| person_ids_in(sgid) }
    end

    def mention_attachment_sgids
      content.to_s.scan(MENTION_ATTACHMENT).map { |attachment| attachment[/\bsgid="([^"]+)"/, 1] }.compact
    end

    def person_ids_in(sgid)
      decode(sgid).scan(PERSON_GID).flatten.map(&:to_i)
    end

    def decode(sgid)
      Base64.decode64(sgid.split("--").first.to_s.tr("-_", "+/"))
    end
end
