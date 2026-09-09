require "json"
require "fileutils"
require "time"

# Which Basecamp people have paired a GitHub identity with this host's agent,
# keyed on the account Person id every event carries as `creator.id`. A
# pairing is the person's own request, the operator's approval, and a
# device-flow consent in the person's browser proving they control the login
# (see GitHub::DeviceFlow); only the login and numeric id are kept — the
# token that proved it is discarded, because nothing here acts *as* them.
# The pairing exists so a worker can name them as git author, honestly.
#
# Two states live in one file: `pending` requests awaiting the operator's
# approval, and `paired` identities. The file is re-read on every lookup —
# it is tiny and events are rare — so a pairing made while the connector
# runs takes effect without a restart.
class BasecampAgentConnector::Pairings
  DEFAULT_PATH = File.expand_path("~/.config/basecamp-connect/pairings.json")
  SECTIONS = %w[pending paired]

  attr_reader :path

  def initialize(path: DEFAULT_PATH)
    @path = path
    @data = SECTIONS.to_h { |section| [ section, {} ] }
  end

  def find(person_id)
    reload
    @data["paired"][person_id.to_s]
  end

  def pending(person_id)
    reload
    @data["pending"][person_id.to_s]
  end

  # The request whose agent reply was boosted, by that reply's URL — what a
  # boost event names is the reply, not the person who asked for the pairing.
  def pending_for_reply(reply_url)
    reload
    @data["pending"].find { |_, request| request["reply_url"] == reply_url } \
      &.then { |person_id, request| request.merge("person_id" => person_id.to_i) }
  end

  def pending_requests
    reload
    @data["pending"].dup
  end

  def paired
    reload
    @data["paired"].dup
  end

  def request(person_id, login:, reply_url:, requested_at: Time.now.utc)
    reload
    @data["pending"][person_id.to_s] = { "login" => login.delete_prefix("@"), "reply_url" => reply_url, "requested_at" => requested_at.iso8601 }
    save
  end

  def pair(person_id, login:, id:, approved_by:, paired_at: Time.now.utc)
    reload
    @data["pending"].delete(person_id.to_s)
    @data["paired"][person_id.to_s] = { "login" => login, "id" => id, "approved_by" => approved_by, "paired_at" => paired_at.iso8601 }
    save
  end

  def remove(person_id)
    reload
    removed = !@data["paired"].delete(person_id.to_s).nil?
    @data["pending"].delete(person_id.to_s)
    save
    removed
  end

  private
    # A missing, unparseable, or mis-shaped file reads as nobody paired, and a
    # mis-shaped entry as that person unpaired: the pipeline reads through
    # here on every event, and a hand-edit must not take it down.
    def reload
      json = JSON.parse(File.read(@path))
      @data = SECTIONS.to_h { |section| [ section, entries(json.is_a?(Hash) ? json[section] : nil) ] }
    rescue JSON::ParserError, SystemCallError
      @data = SECTIONS.to_h { |section| [ section, {} ] }
    end

    def entries(section)
      section.is_a?(Hash) ? section.select { |_, entry| entry.is_a?(Hash) } : {}
    end

    # Written beside and renamed over, so the connector, which reads this on
    # every event, never sees a half-written file.
    def save
      FileUtils.mkdir_p File.dirname(@path), mode: 0o700
      File.write "#{@path}.tmp", JSON.pretty_generate(@data) + "\n", perm: 0o600
      File.rename "#{@path}.tmp", @path
      self
    end
end
