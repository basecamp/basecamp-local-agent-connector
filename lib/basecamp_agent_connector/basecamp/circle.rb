# A ping conversation — Basecamp's direct message — addressed the only way the
# API allows.
#
# A ping is a `Chat::Transcript` living in a `Circle` bucket, so it answers the
# documented Campfire line endpoints and nothing else. That matters because none
# of the obvious routes work: `circles.json` and `circles/<id>.json` return an
# empty envelope, a Circle is absent from `recordings`, and `RecordingUrl` turns
# the notification's `/circles/<id>` app URL into a path that resolves to nothing.
# The one field carrying both ids is the notification's `subscription_url`, which
# is why discovery parses that rather than the URL a human would click.
#
# Reaching a ping therefore needs two ids where every other recording needs one,
# and they travel together everywhere — through PollState as a single key, since
# remembering a circle without its transcript remembers something unreadable.
class BasecampAgentConnector::Basecamp::Circle
  SUBSCRIPTION_URL = %r{/buckets/(?<id>\d+)/recordings/(?<transcript>\d+)/subscription\.json}

  KEY = /\A(?<id>\d+):(?<transcript>\d+)\z/

  PINGS_SECTION = "pings"

  SEPARATOR = ":"

  # A ping notification is one per conversation, not one per message: its
  # `readable_sgid` decodes to the transcript, and Basecamp re-marks that same
  # record unread as new lines arrive. One measured on 2026-08-26 carried
  # `created_at` from February 2025 and `updated_at` from that afternoon. So the
  # notification is a pointer to a conversation and never an event in itself, and
  # nothing downstream may dedupe on its id.
  def self.ping?(notification)
    notification["section"].to_s == PINGS_SECTION
  end

  def self.from_notification(notification)
    match = SUBSCRIPTION_URL.match(notification["subscription_url"].to_s)
    return nil if match.nil?

    new id: match[:id].to_i, transcript: match[:transcript].to_i, title: notification["bucket_name"]
  end

  def self.from_key(key)
    match = KEY.match(key.to_s)
    return nil if match.nil?

    new id: match[:id].to_i, transcript: match[:transcript].to_i
  end

  attr_reader :id, :transcript, :title

  def initialize(id:, transcript:, title: nil)
    @id = id
    @transcript = transcript
    @title = title
  end

  def key
    [ id, transcript ].join(SEPARATOR)
  end

  def lines_path(page: nil)
    path = "buckets/#{id}/chats/#{transcript}/lines.json"
    page.nil? ? path : "#{path}?page=#{page}"
  end

  def subscription_path
    "buckets/#{id}/recordings/#{transcript}/subscription.json"
  end

  def to_s
    title.nil? ? key : "#{title} (#{key})"
  end

  def ==(other)
    other.is_a?(self.class) && other.key == key
  end
  alias eql? ==

  def hash
    key.hash
  end
end
