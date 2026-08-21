require "base64"

class BasecampAgentConnector::Basecamp::Event
  # Assignment events (`todo_assignment_changed`, `kanban_card_assignment_changed`,
  # `kanban_step_assignment_changed`) are a second way to trigger the agent: the
  # operator assigns it a card/todo rather than @mentioning it. Their `details`
  # carry `added_person_ids` / `removed_person_ids`.
  ASSIGNMENT_KIND_SUFFIX = "_assignment_changed"

  ACTIONABLE_KIND_SUFFIXES = [ "_created", "_content_changed", ASSIGNMENT_KIND_SUFFIX ]

  CARD_CREATED_KIND = "kanban_card_created"


  MENTION_CONTENT_TYPE = "application/vnd.basecamp.mention"

  # The webhook delivers a mention as an unexpanded attachment carrying only an
  # SGID and content-type — no rendered name. The agent's account-scoped Person
  # id is encoded inside the SGID, so match on that id rather than a display name.
  #
  # Match the whole opening tag quote-aware: a mention attachment also carries a
  # `content="…"` attribute whose value is embedded markup full of `>` characters,
  # and webhooks order the attributes sgid, content, content-type (the API renders
  # them sgid, content-type, content). A `[^>]*` matcher would stop at the first
  # `>` inside that content value and miss a trailing content-type, so consume
  # quoted values whole and test the attributes against the captured tag instead.
  BC_ATTACHMENT_TAG = /<bc-attachment\b(?:"[^"]*"|'[^']*'|[^"'>])*>/i

  MENTION_CONTENT_TYPE_ATTRIBUTE = /content-type="#{Regexp.escape(MENTION_CONTENT_TYPE)}"/i

  SGID_ATTRIBUTE = /\bsgid="([^"]+)"/

  PERSON_GID = %r{gid://bc3/Person/(\d+)}

  EMITTED_RECORDING_FIELDS = %w[id type title app_url url content parent bucket]
  EMITTED_CREATOR_FIELDS = %w[id name email_address]
  EMITTED_DETAIL_FIELDS = %w[added_person_ids removed_person_ids]

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

  def bucket_id
    recording.dig("bucket", "id")
  end

  # A card's parent is its column (`Kanban::Column`), never its board — the card
  # table's id appears nowhere in the payload. That is why a watched surface is
  # specified as a column rather than as a table: the column id arrives already
  # matchable, and resolving a table would cost an API call per delivery.
  def column_id
    recording.dig("parent", "id")
  end

  def recording_app_url
    recording["app_url"]
  end

  def content
    recording["content"]
  end

  def details
    @payload["details"] || {}
  end

  def added_person_ids
    details["added_person_ids"] || []
  end

  def actionable_kind?
    kind.end_with?(*ACTIONABLE_KIND_SUFFIXES)
  end

  def assignment_changed?
    kind.end_with?(ASSIGNMENT_KIND_SUFFIX)
  end

  def card_created?
    kind == CARD_CREATED_KIND
  end

  # The account-scoped person id decides this, and email is only the fallback for
  # a payload that carries no creator id. Basecamp masks other people's addresses
  # on a recording read — the operator's comes back as `f••••••••@••••••••.•••` —
  # so an email comparison answers false for every event he authored, and the two
  # triggers that route through here, mentions and assignments, both go dead while
  # watched-column creations keep working. Ids are never masked.
  def authored_by?(identity)
    if !creator_id.nil? && !identity.person_id.nil?
      creator_id == identity.person_id
    elsif !creator_email.nil? && !identity.email.nil?
      creator_email.casecmp?(identity.email)
    else
      false
    end
  end

  def mentions?(agent)
    return false if agent.person_id.nil?

    mentioned_person_ids.include?(agent.person_id)
  end

  def assigns?(agent)
    return false if agent.person_id.nil?

    assignment_changed? && added_person_ids.include?(agent.person_id)
  end

  def to_emitted_hash
    {
      "event_id" => id,
      "kind" => kind,
      "created_at" => created_at,
      "creator" => creator.slice(*EMITTED_CREATOR_FIELDS),
      "details" => details.slice(*EMITTED_DETAIL_FIELDS),
      "recording" => recording.slice(*EMITTED_RECORDING_FIELDS)
    }
  end

  private
    def mentioned_person_ids
      mention_attachment_sgids.flat_map { |sgid| person_ids_in(sgid) }
    end

    def mention_attachment_sgids
      content.to_s.scan(BC_ATTACHMENT_TAG)
        .select { |tag| tag.match?(MENTION_CONTENT_TYPE_ATTRIBUTE) }
        .map { |tag| tag[SGID_ATTRIBUTE, 1] }
        .compact
    end

    def person_ids_in(sgid)
      decode(sgid).scan(PERSON_GID).flatten.map(&:to_i)
    end

    def decode(sgid)
      Base64.decode64(sgid.split("--").first.to_s.tr("-_", "+/"))
    end
end
