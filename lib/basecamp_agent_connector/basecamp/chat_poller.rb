require "set"
require "time"

# Campfire coverage. Basecamp never delivers chat lines by webhook — bc3
# hard-excludes every /^chat/ event kind from webhook relay ("chat is high
# volume and will have its own API") and rejects Chat::Line as a registrable
# type — so the only way to hear a Campfire @mention is to poll the chat lines
# API. Each watched project's chats are discovered up front (and re-discovered
# periodically, so a Campfire added mid-session gets covered and a deleted one
# stops being polled); on an interval the newest lines of each are fetched, and
# every not-yet-seen line is synthesized into a chat-kind event and fed through
# its own Pipeline instance with the same authorizer pre-filter, corroborating
# re-fetch, authoritative re-check, and STDOUT funnel as webhook deliveries.
#
# History is never dispatched: a line that predates the poller is marked seen
# without being processed — on the first fetch (so connecting never replays a
# chat's history) and on any later fetch a deletion slides it back into the
# window. Lines posted since the poller started always process, even on a
# room's first fetch, so a Campfire discovered late (created mid-session, or
# listed only after a startup failure) doesn't swallow the mentions that
# arrived before then. Seen ids accumulate one integer per new line for the
# session — small enough to keep unpruned. Edits to an already-seen line
# don't re-trigger (chat coverage is `*_created` only, and there is no edit
# event to observe).
class BasecampAgentConnector::Basecamp::ChatPoller
  DEFAULT_INTERVAL = 15
  FETCH_LIMIT = 50
  REDISCOVER_AFTER = 600

  Room = Data.define(:project, :chat_id, :title)

  def initialize(basecamp_cli:, pipeline:, projects:, interval: DEFAULT_INTERVAL, logger: $stderr,
    wait: ->(seconds) { sleep seconds }, clock: -> { Time.now })
    @basecamp_cli = basecamp_cli
    @pipeline = pipeline
    @projects = projects
    @interval = interval
    @logger = logger
    @wait = wait
    @clock = clock
    @rooms_by_project = {}
    @refreshed_at = {}
    @seen_line_ids = {}
    # Floored to the whole second because line timestamps may carry only
    # second precision: comparing a sub-second start against a truncated
    # created_at would misfile a line posted just after start as history and
    # drop it for good. See posted_since_start?.
    @started_at = @clock.call.floor
    @stopping = false
  end

  # Discovers synchronously — so the caller can report an accurate room count
  # the moment start returns — but emits nothing until the poll thread's first
  # pass, one interval later. Nothing can land on the funnel before the
  # connector has reported readiness and its consumer is watching; a mention
  # posted in the meantime is not lost, because post-start lines process even
  # on a room's first fetch.
  def start
    discovered = rooms
    @thread = Thread.new { poll_loop }
    discovered
  end

  def stop
    @stopping = true

    if @thread
      @thread.kill
      # Bounded, not guaranteed: a kill lands between CLI calls instantly, but
      # a thread mid-subprocess dies only when the child returns. The process
      # is tearing down anyway, so make any residue visible rather than block.
      log "chat poll thread did not stop within 5s" if @thread.join(5).nil?
      @thread = nil
    end
  end

  def poll
    rooms.each { |room| poll_room(room) } unless @stopping
  end

  # Discovery is per project: a project whose listing fails keeps its stale
  # rooms covered and is retried on the next poll (logged each time — missing
  # coverage should stay visible), while healthy projects refresh on their own
  # REDISCOVER_AFTER cadence, untouched by a neighbor's failures.
  def rooms
    @projects.flat_map { |project| rooms_for(project) || [] }
  end

  private
    def rooms_for(project)
      refresh(project) if due_for_discovery?(project)
      @rooms_by_project[project]
    end

    def due_for_discovery?(project)
      !@rooms_by_project.key?(project) || \
        @clock.call - @refreshed_at.fetch(project) >= REDISCOVER_AFTER
    end

    # A failure changes nothing: known rooms stay covered, and the unadvanced
    # timestamp leaves the project due again on the very next poll.
    def refresh(project)
      discovered = discover(project)

      unless discovered.nil?
        @rooms_by_project[project] = discovered
        @refreshed_at[project] = @clock.call
      end
    end

    def discover(project)
      @basecamp_cli.chats(project: project).map do |chat|
        Room.new(project: project, chat_id: chat["id"], title: chat["title"])
      end
    rescue BasecampAgentConnector::Basecamp::Client::Error => error
      log "could not list chats for project #{project}: #{error.message}"
      nil
    end

    # The loop is the only chat thread there is; an exception that escapes a
    # poll (discovery is outside poll_room's own rescue) must cost one tick,
    # not all coverage for the rest of the session.
    def poll_loop
      until @stopping
        @wait.call(@interval)

        begin
          poll
        rescue => error
          log "chat poll failed: #{error.message}"
        end
      end
    end

    # One rule for every fetched line, first fetch or fiftieth: already seen —
    # skip; posted since the poller started — process; otherwise it is history
    # and is marked seen silently. The last case covers both the initial
    # baseline and a pre-start line that a deletion slides back into the
    # newest-N window later — either way, history is never dispatched.
    def poll_room(room)
      lines = @basecamp_cli.chat_lines(project: room.project, chat: room.chat_id, limit: FETCH_LIMIT)
      first_fetch = !@seen_line_ids.key?(room.chat_id)
      seen = @seen_line_ids[room.chat_id] ||= Set.new
      ordered = lines.sort_by { |line| line["id"].to_i }
      warn_of_possible_overflow(room, ordered, seen, first_fetch)

      ordered.each do |line|
        if seen.include?(line["id"])
          # already handled
        elsif posted_since_start?(line)
          process(line, seen)
        else
          seen << line["id"]
        end
      end
    rescue => error
      # Broad on purpose: one bad room (or a pipeline bug) must not kill the
      # poll thread or starve the other rooms.
      log "chat poll failed for #{room.title.inspect} in project #{room.project}: #{error.message}"
    end

    # Fail toward history: a line whose timestamp is missing or unreadable is
    # baselined rather than risking a replay. The boundary itself leans the
    # other way: @started_at is floored to the second and the comparison is
    # inclusive, so a line stamped in the poller's start second counts as
    # post-start even when its created_at carries only second precision —
    # dispatching a same-second, essentially-concurrent mention beats
    # permanently dropping one posted just after start. Comparing server
    # timestamps against the local clock assumes NTP-grade sync; skew shifts
    # the history boundary by its own magnitude (ahead: that many seconds of
    # post-start lines counted as history; behind: that many seconds of
    # pre-start lines dispatched, still corroborated and authorized). An
    # unsynced clock, e.g. right after a snapshot restore or laptop resume,
    # widens that sliver.
    def posted_since_start?(line)
      created_at = line["created_at"].to_s
      !created_at.empty? && Time.iso8601(created_at) >= @started_at
    rescue ArgumentError
      false
    end

    # Seen means settled. A line the pipeline could not corroborate — the
    # corroborating fetch failed, which a transient API or CLI blip can cause
    # as easily as a deletion — is forgotten again so the next poll retries it
    # while it remains in the window; a deleted line simply stops appearing.
    # A pipeline exception leaves the line seen: retrying a bug every tick
    # would only repeat it.
    def process(line, seen)
      seen << line["id"]
      seen.delete(line["id"]) unless @pipeline.process(BasecampAgentConnector::Basecamp::Event.chat_line_payload(line))
    end

    # The fetch window is a bound: if a chat produced more than FETCH_LIMIT
    # lines between polls (or since the poller started, for a first fetch),
    # the overflow scrolled out unseen. A full window that carries no proof of
    # continuity — no overlap with seen lines, or on a first fetch not even a
    # pre-start line — doesn't prove a gap, but say so.
    def warn_of_possible_overflow(room, ordered, seen, first_fetch)
      if ordered.length == FETCH_LIMIT && overflow_suspected?(ordered, seen, first_fetch)
        log "possible chat window overflow for #{room.title.inspect} in project #{room.project}: " \
          "every fetched line is new; lines beyond the #{FETCH_LIMIT}-line window may have been missed"
      end
    end

    def overflow_suspected?(ordered, seen, first_fetch)
      if first_fetch
        posted_since_start?(ordered.first)
      else
        ordered.none? { |line| seen.include?(line["id"]) }
      end
    end

    def log(message)
      @logger.puts message
    end
end
