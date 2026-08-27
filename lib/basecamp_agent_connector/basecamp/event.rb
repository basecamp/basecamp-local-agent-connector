require "base64"

class BasecampAgentConnector::Basecamp::Event
  # Assignment events (`todo_assignment_changed`, `kanban_card_assignment_changed`,
  # `kanban_step_assignment_changed`) are a second way to trigger the agent: the
  # operator assigns it a card/todo rather than @mentioning it. Their `details`
  # carry `added_person_ids` / `removed_person_ids`.
  ASSIGNMENT_KIND_SUFFIX = "_assignment_changed"

  ACTIONABLE_KIND_SUFFIXES = [ "_created", "_content_changed", ASSIGNMENT_KIND_SUFFIX ]

  # Basecamp never delivers chat events by webhook: bc3 hard-excludes every
  # /^chat/ event kind from webhook relay and rejects Chat::Line as a
  # registrable type. Chat-kind events therefore exist only as events the
  # ChatPoller synthesizes from lines it fetched itself — and a chat-kind
  # payload arriving on the webhook route is by definition not from Basecamp.
  CHAT_KIND_PREFIX = "chat_"

  # A third way to trigger the agent: a new comment on a recording it subscribes
  # to, with no @mention. A new comment always hangs off a subscribable parent
  # (the commented-on todo/card/message), so `comment_created` is the one kind
  # that can trigger by subscription. Whether the agent actually subscribes is a
  # live API fact the Verifier corroborates and stamps onto the authoritative
  # event under `agent_subscribed`; a raw webhook payload never carries it.
  COMMENT_CREATED_KIND = "comment_created"

  # A fourth way to trigger the agent: someone boosts a recording of the
  # agent's. Basecamp never delivers boosts by webhook — in bc3 a Boost is not
  # a Recording and creates no Event, so there is no kind to even subscribe
  # to. Boost-kind events exist only as events the BoostPoller synthesizes
  # from the agent's own received-boosts feed, named as bc3 would have named
  # the event had one existed (Boost => boost_created) — and a boost-kind
  # payload arriving on the webhook route is by definition not from Basecamp.
  BOOST_KIND = "boost_created"

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
  EMITTED_DETAIL_FIELDS = %w[added_person_ids removed_person_ids boost]

  def self.from_payload(payload)
    new(payload)
  end

  # The ChatPoller has no webhook envelope to parse, so it synthesizes one per
  # new line: the line is the recording, its author the creator, and the kind is
  # what bc3 would have named the event had chat kinds been relayed
  # (Chat::Lines::RichText => chat_lines_rich_text_created).
  def self.chat_line_payload(line)
    {
      "id" => line["id"],
      "kind" => chat_line_kind(line["type"]),
      "created_at" => line["created_at"],
      "creator" => line["creator"] || {},
      "recording" => line
    }
  end

  def self.chat_line_kind(type)
    "#{type.to_s.gsub("::", "_").gsub(/([a-z\d])([A-Z])/, '\1_\2').downcase}_created"
  end

  # The BoostPoller has no webhook envelope to parse, so it synthesizes one per
  # new feed entry: the boosted recording is the recording, the booster is the
  # creator, and the boost's own id and content ride in `details`.
  def self.boost_payload(boost)
    {
      "id" => boost["id"],
      "kind" => BOOST_KIND,
      "created_at" => boost["created_at"],
      "creator" => boost["booster"] || {},
      "details" => { "boost" => boost.slice("id", "content") },
      "recording" => boost["recording"] || {}
    }
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

  def chat_kind?
    kind.start_with?(CHAT_KIND_PREFIX)
  end

  def subscribable_comment?
    kind == COMMENT_CREATED_KIND
  end

  def boost?
    kind == BOOST_KIND
  end

  def authored_by?(identity)
    return false if creator_email.nil? || identity.email.nil?

    creator_email.casecmp?(identity.email)
  end

  def mentions?(agent)
    return false if agent.person_id.nil?

    mentioned_person_ids.include?(agent.person_id)
  end

  def assigns?(agent)
    return false if agent.person_id.nil?

    assignment_changed? && added_person_ids.include?(agent.person_id)
  end

  # True only on an authoritative event the Verifier stamped after confirming,
  # against the live subscribers API, that the agent subscribes to the comment's
  # parent. Reads nothing from the forgeable webhook payload.
  def subscribed?
    @payload["agent_subscribed"] == true
  end

  # True only on an authoritative event the Verifier stamped after re-fetching
  # the agent's own received-boosts feed and finding this boost in it — the
  # feed files a boost under the person it was aimed at, so membership is the
  # targeting fact. Reads nothing from a forgeable payload.
  def boosted?
    @payload["agent_boosted"] == true
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
