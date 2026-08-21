require "json"
require "fileutils"

# What the poller has already handled, kept on disk so a restart does not replay
# a night's work. Pipeline dedupes within a run; this dedupes across runs.
#
# Ids are held per source and capped, because the surfaces being watched only
# ever grow: an uncapped file would accumulate every notification the bot has
# received. The cap is far above a round's worth, so the only ids that fall off
# are ones no listing still returns.
class BasecampAgentConnector::PollState
  DEFAULT_PATH = File.expand_path("~/.config/basecamp-connect/poll-state.json")

  IDS_PER_SOURCE = 500

  def initialize(path: DEFAULT_PATH)
    @path = path
    @sources = load
  end

  def seen?(source, id)
    return false if key(id).empty?

    ids(source).include?(key(id))
  end

  def record(source, id)
    return if key(id).empty?

    ids(source) << key(id)
  end

  # Recording an id is a promise that the event was handled. When the promise
  # turns out to be false -- the Verifier could not reach Basecamp to corroborate
  # it, so nothing was emitted -- the memory has to come back out, or the event is
  # lost for good on a blip.
  def forget(source, id)
    return if key(id).empty?

    ids(source).delete key(id)
  end

  def empty?
    @sources.values.all?(&:empty?)
  end

  def save
    FileUtils.mkdir_p File.dirname(@path)
    File.write @path, JSON.pretty_generate(capped)
  end

  private
    def ids(source)
      @sources[source] ||= []
    end

    # Ids arrive as integers from a listing and as strings from JSON, and the two
    # have to compare equal or every restart replays everything.
    def key(id)
      id.to_s
    end

    # A blank key is dropped on the way in as well as on the way out: one written
    # by an earlier version would otherwise keep matching every idless record.
    def load
      parsed = JSON.parse(File.read(@path))
      parsed.transform_values { |ids| Array(ids).map { |id| key(id) }.reject(&:empty?) }
    rescue Errno::ENOENT, JSON::ParserError
      {}
    end

    def capped
      @sources.transform_values { |ids| ids.last(IDS_PER_SOURCE) }
    end
end
