# Which session an event belongs to.
#
# A session is about a *thing of work* — a card, a todo, a message, a document
# — not about each remark made on it. So a comment does not open a session of
# its own: it joins the one its parent already owns, and the card's whole
# history (its description, every earlier comment, and everything the agent
# worked out doing the last request) is still in context when the next comment
# arrives. That is the point of dispatching per task rather than per event:
# re-reading a card from Basecamp recovers its text, never the reasoning that
# followed from it.
#
# The root is therefore the parent for a recording that is only ever attached
# to something else — a Comment, a chat line — and the recording itself
# otherwise. Everything needed is already on the emitted event, so settling
# this costs no API call.
#
# Chat rooms are the one uncomfortable fit: a Campfire line's root is the room,
# so a room maps to one long-lived session rather than one per exchange. That
# is deliberate — chat is a continuous conversation and splitting it per line
# would defeat the purpose — but it does mean a busy room's session runs until
# something ends it.
class BasecampAgentConnector::Session::Key
  # Recordings that are always hung off a parent, and so never own a session.
  ATTACHED_TYPES = [ "Comment" ].freeze
  ATTACHED_TYPE_PREFIXES = [ "Chat::Lines" ].freeze

  attr_reader :agent, :bucket_id, :type, :id, :title

  # Returns nil for an event that names no recording — a GitHub review line,
  # which is about a pull request and has no Basecamp thing of work to hang a
  # session on.
  def self.from_event(event, agent:)
    recording = event["recording"]
    return nil if recording.nil?

    root = root_of(recording)
    return nil if root.nil? || root["id"].nil?

    new(agent: agent, bucket_id: recording.dig("bucket", "id"), type: root["type"], id: root["id"],
      title: root["title"] || recording["title"])
  end

  # A comment's parent is the card/message/todo it lives on. Anything else is
  # already the thing of work. A parent that is itself missing an id (a
  # truncated payload) leaves the recording as its own root rather than
  # dropping the event.
  def self.root_of(recording)
    return recording unless attached?(recording["type"])

    parent = recording["parent"]
    parent.nil? || parent["id"].nil? ? recording : parent
  end

  def self.attached?(type)
    type = type.to_s
    ATTACHED_TYPES.include?(type) || ATTACHED_TYPE_PREFIXES.any? { |prefix| type.start_with?(prefix) }
  end

  def initialize(agent:, bucket_id:, type:, id:, title: nil)
    @agent = agent
    @bucket_id = bucket_id
    @type = type
    @id = id
    @title = title
  end

  # Also the registry's filename, so every character that is not plainly safe
  # in one is folded away. `Kanban::Card` and `Kanban-Card` would collide, but
  # only for the same id in the same bucket — the same card either way.
  def to_s
    [ agent, bucket_id, type, id ].map { |part| part.to_s.gsub(/[^A-Za-z0-9_.-]+/, "-") }.join("_")
  end

  # What the session is called in `claude agents`. The card's own title is what
  # makes that listing readable at a glance, so it is preferred over anything
  # synthesized from ids.
  def display_name
    name = title.to_s.strip
    name.empty? ? "#{type} #{id}" : name
  end

  def ==(other)
    other.is_a?(self.class) && other.to_s == to_s
  end
  alias eql? ==

  def hash
    to_s.hash
  end
end
