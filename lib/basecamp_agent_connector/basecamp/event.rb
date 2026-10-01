require "base64"

class BasecampAgentConnector::Basecamp::Event
  # Assignment events (`todo_assignment_changed`, `kanban_card_assignment_changed`,
  # `kanban_step_assignment_changed`) are a second way to trigger the agent: the
  # operator assigns it a card/todo rather than @mentioning it. Their `details`
  # carry `added_person_ids` / `removed_person_ids`.
  ASSIGNMENT_KIND_SUFFIX = "_assignment_changed"

  # Publishing a draft is the one way a recording becomes visible without a
  # `_created` event ever reaching here. bc3 records the `created` event while
  # the recording is still drafted and refuses to relay it — Webhook's
  # `eligible_event?` drops any event whose recording is `drafted?`, so drafts
  # cannot leak — and it never re-relays that event at publish time. What it
  # relays instead is the status change itself: publishing moves the recording
  # drafted => active, which Recording::Eventable tracks as the action `active`
  # and Event#set_kind names `<container>_active` (`message_active`,
  # `document_active`, `upload_active`). So a mention typed into a draft
  # reaches the connector under this suffix or not at all.
  DRAFT_PUBLISHED_KIND_SUFFIX = "_active"

  ACTIONABLE_KIND_SUFFIXES = \
    [ "_created", "_content_changed", DRAFT_PUBLISHED_KIND_SUFFIX, ASSIGNMENT_KIND_SUFFIX ]

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

  # A fifth way to trigger the agent: someone writes in a Ping — the
  # direct-message space bc3 models as a `Circle` bucket holding one
  # `Chat::Transcript`. A ping needs no @mention to be aimed at the agent;
  # being in the room is the addressing, which is how bc3's own agent inbox
  # files it (`reason: "pinged"` — "a participant in the Circle (Ping) the
  # line was posted to"). That inbox is agents-only and answers 403 to a
  # User-backed agent like this connector's, so ping events exist only as
  # events the PingPoller synthesizes from the agent's notification feed and
  # the Circle's own lines endpoint.
  #
  # A ping line *is* a chat line — same type, same endpoints — so it needs no
  # kind of its own. What tells the two apart is the bucket the line lives
  # in, and that is read off the recording rather than off the kind: the kind
  # is what a payload claimed, the bucket is what Basecamp recorded.
  CIRCLE_BUCKET_TYPE = "Circle"

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

  # A chat line whose bucket is a Circle: a ping. Both halves matter. The kind
  # keeps a forged non-chat payload from claiming ping targeting, and the
  # bucket keeps a Campfire line from claiming it — Campfire membership is a
  # whole project, not a direct message, so a Campfire line still owes the
  # mention every other chat line owes.
  def ping?
    chat_kind? && bucket_type == CIRCLE_BUCKET_TYPE
  end

  def bucket_type
    recording.dig("bucket", "type")
  end

  def bucket_id
    recording.dig("bucket", "id")
  end

  # A chat line's transcript. It addresses the conversation everywhere the
  # bucket alone cannot — the lines endpoint, and the subscription read that
  # decides who else is in a Ping.
  def transcript_id
    recording.dig("parent", "id")
  end

  def subscribable_comment?
    kind == COMMENT_CREATED_KIND
  end

  def boost?
    kind == BOOST_KIND
  end

  # Email or account Person id — either key identifies the author. Email alone
  # is not enough: bc3 redacts other users' addresses from non-admin viewers
  # (`Person#can_see_email_address_of?` is self-or-admin), so a feed the agent
  # fetches shows every other booster as `j••••@••••.•••`. The Person id is
  # visible to every viewer and is the same account-scoped id space the
  # webhook's `creator.id` uses, so it matches where a redacted email cannot.
  def authored_by?(identity)
    authored_by_email?(identity) || authored_by_person_id?(identity)
  end

  def mentions?(agent)
    return false if agent.person_id.nil?

    mentioned_person_ids.include?(agent.person_id)
  end

  def assigns?(agent)
    return false if agent.person_id.nil?

    assignment_changed? && added_person_ids.include?(agent.person_id)
  end

  # True only on an authoritative event the Verifier stamped after matching the
  # re-fetched recording's mention attachments against the agent's Person id —
  # the same `mentions?` verdict the pipeline trusts, settled on the
  # authoritative content rather than the forgeable webhook payload.
  def mentioned?
    @payload["agent_mentioned"] == true
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

  # True only on an authoritative event the Verifier stamped after re-reading
  # the Circle's subscription as the agent and finding the room private to the
  # agent and its operator. Reads nothing from a forgeable payload.
  def pinged?
    @payload["agent_pinged"] == true
  end

  # The top-level keys mirror the webhook envelope; `trigger` is the one
  # connector-owned key, carrying the Verifier's verdicts on why this event
  # targets the agent. Without it a watcher can tell a mention from a
  # followed-thread comment only by decoding the mention markup itself against
  # the agent's Person id. Assignments and boosts already announce themselves
  # by `kind`, so these are the verdicts a watcher cannot derive.
  #
  # `pinged` is the starkest of them: a ping line carries *nothing* saying the
  # agent was addressed — no mention markup to decode, just a line in a room —
  # and its kind is an ordinary chat kind, so without this stamp a watcher
  # would read a direct message as any other Campfire chatter.
  def to_emitted_hash
    {
      "event_id" => id,
      "kind" => kind,
      "created_at" => created_at,
      "creator" => creator.slice(*EMITTED_CREATOR_FIELDS),
      "details" => details.slice(*EMITTED_DETAIL_FIELDS),
      "recording" => recording.slice(*EMITTED_RECORDING_FIELDS),
      "trigger" => { "mentioned" => mentioned?, "subscribed" => subscribed?, "pinged" => pinged? }
    }
  end

  private
    def authored_by_email?(identity)
      !creator_email.nil? && !identity.email.nil? && creator_email.casecmp?(identity.email)
    end

    def authored_by_person_id?(identity)
      !identity.person_id.nil? && creator_id == identity.person_id
    end

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
