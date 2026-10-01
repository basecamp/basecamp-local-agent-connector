require "set"
require "time"

# Ping coverage. A Ping is Basecamp's direct message — bc3 models it as a
# `Circle`, a bucket of its own holding one `Chat::Transcript` — and it reaches
# the agent by no route this connector already had. Webhooks are registered per
# project and a Circle is not a project, so there is nothing to register
# against; and even if there were, bc3 hard-excludes every /^chat/ event kind
# from webhook relay, which a ping line is. The ChatPoller cannot see one
# either: it discovers rooms with `chat list` on each watched project, and
# `/chats.json` serves only project Campfires (verified against production — a
# Circle never appears in it).
#
# bc3 does have a purpose-built answer: `GET /inbox.json`, the addressed-items
# feed, whose `pinged` reason is exactly "a participant in the Circle (Ping)
# the line was posted to". It is agents-only — "any other principal receives
# 403 Forbidden" — and an agent here is a full `User` account rather than the
# `Agent` personable, so it draws that 403 today (verified against
# production). When that changes, this poller should give way to that feed.
#
# Until then the one API-readable place a received ping surfaces is the
# agent's own notification inbox, `/my/readings.json`, whose rows carry a
# `section` and where a ping's is "pings". So: on an interval that feed is
# read as the agent and each ping row names a Ping; each newly named Ping is
# remembered and its transcript polled — as the agent, because Basecamp
# serves a Circle to nobody else — with every not-yet-seen line synthesized
# into a chat-line event and fed through its own Pipeline instance with the
# same authorizer pre-filter, corroborating re-fetch, authoritative re-check,
# and STDOUT funnel as webhook deliveries.
#
# Discovery and reading are deliberately different mechanisms, and nothing
# may dedupe on the notification. A ping notification is ONE row per
# conversation, which Basecamp re-marks unread as new lines arrive: its
# `created_at` is when the conversation started and its `updated_at` is the
# newest line. Deduplicating on it would fire on a Ping's first line and
# swallow every one after. Dedupe is on the line id, and the feed is asked
# one question only — which Pings exist. Once a room is known it is polled
# directly and stays polled, so nothing about how Basecamp bundles, caps or
# ages notifications can hide a line in a room already being watched.
#
# The room ids come from the notification's `subscription_url`, the one field
# carrying the Circle and its transcript together, rather than from the
# `app_url` a human would click — which names the Circle alone, and a Circle
# alone addresses nothing readable.
#
# What makes a ping line a trigger is the room, not the words: a ping needs no
# @mention, because writing in a two-person Circle with the agent is already
# writing at it. Asking for a mention there would be asking for what the
# conversation already is. What stands in its place is the Verifier's
# subscription read — the room must hold the agent and its operator and
# nobody else — and the ordinary authorizer pre-filter on top, so a line the
# operator did not write is dropped exactly as a mention from that author
# would be.
#
# History is never dispatched: a line that predates the poller is marked seen
# without being processed — on a room's first fetch (so connecting never
# replays a conversation) and on any later fetch a deletion slides it back
# into the window. Lines posted since the poller started always process, even
# on a room's first fetch, so a Ping opened mid-session — or one found late,
# after a startup failure — doesn't swallow the lines that arrived before it
# was found. Seen ids accumulate one integer per new line for the session,
# small enough to keep unpruned; edits to an already-seen line don't
# re-trigger. The agent's own replies land in the same conversation, are read
# on the next tick, and are passed over: the authorizer refuses the agent's
# own identity outright.
class BasecampAgentConnector::Basecamp::PingPoller
  DEFAULT_INTERVAL = 30

  FETCH_LIMIT = 50

  # bc3's readings feed caps `unreads` at 100 and paginates `reads` at 50 per
  # page; only the first page is fetched. The server owns those numbers —
  # this is a hint for the overflow warning, not a request parameter.
  FEED_WINDOW = 150

  MAX_BACKOFF = 300

  # `unreads` is where a line that just arrived puts its conversation, and
  # `reads` is what still names a Ping the agent has already caught up on.
  # Only the section marks a row as a ping: its title is the literal word
  # "Ping" and its type is "Chat", neither of which tells one from a Campfire.
  FEED_SECTIONS = %w[unreads reads]
  PING_SECTION = "pings"

  # The notification's `subscription_url` — `…/buckets/<circle>/recordings/
  # <transcript>/subscription.json` — is the only field where both ids appear
  # together (verified against production).
  SUBSCRIPTION_URL = %r{/buckets/(\d+)/recordings/(\d+)/subscription\.json}

  Room = Data.define(:circle_id, :chat_id, :title)

  def initialize(basecamp_cli:, pipeline:, agent:, interval: DEFAULT_INTERVAL, logger: $stderr,
    wait: ->(seconds) { sleep seconds }, clock: -> { Time.now })
    @basecamp_cli = basecamp_cli
    @pipeline = pipeline
    @agent = agent
    @interval = interval
    @logger = logger
    @wait = wait
    @clock = clock
    @rooms_by_circle_id = {}
    @seen_line_ids = {}
    # Floored to the whole second because line timestamps may carry only
    # second precision: comparing a sub-second start against a truncated
    # created_at would misfile a line posted just after start as history and
    # drop it for good. See posted_since_start?.
    @started_at = @clock.call.floor
    @stopping = false
    @rate_limited = false
    @backoff = nil
  end

  # Discovers synchronously — so the caller can report an accurate room count
  # the moment start returns — but emits nothing until the poll thread's first
  # pass, one interval later. Nothing can land on the funnel before the
  # connector has reported readiness and its consumer is watching; a ping sent
  # in the meantime is not lost, because post-start lines process even on a
  # room's first fetch.
  def start
    discovered = discover_rooms
    # A refusal during this synchronous discovery already proves the budget
    # is exhausted — let the first wait back off instead of retrying at the
    # configured cadence.
    extend_backoff if @rate_limited
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
      log "ping poll thread did not stop within 5s" if @thread.join(5).nil?
      @thread = nil
    end
  end

  def poll
    unless @stopping
      @rate_limited = false

      begin
        # Discovery first, so a Ping opened since the last tick is read on
        # this one rather than the next.
        discover_rooms

        # One refusal is the account's shared budget saying no to everyone,
        # so spending the rest of the tick's calls would only be refused
        # too: stop at the first and let the backed-off next tick retry.
        rooms.each do |room|
          break if @rate_limited
          poll_room(room)
        end
      ensure
        # In an ensure so a tick a bug crashes still settles: it drew no
        # refusal, so it resets, and the crash stays visible via poll_loop.
        @rate_limited ? extend_backoff : reset_backoff
      end
    end
  end

  # Every Ping this poller has found, in the order it found them. A room is
  # never dropped: the readings feed is a notification inbox, so a quiet
  # conversation ages out of it, and forgetting the room would stop polling
  # a conversation that is merely paused. A Ping the agent has been removed
  # from stops answering instead, and says so once per tick.
  def rooms
    @rooms_by_circle_id.values
  end

  private
    # The feed is asked one question — which Pings exist — and answers with
    # one row per conversation. A row for a room already known changes
    # nothing; a row for a new one is remembered by the pair of ids in its
    # `subscription_url`. No second call: everything a room needs to be
    # polled is in the row.
    def discover_rooms
      ping_rows.each do |row|
        room = room_in(row)
        next if room.nil? || @rooms_by_circle_id.key?(room.circle_id)

        @rooms_by_circle_id[room.circle_id] = room
        log "Found a Ping with @#{agent_name}: #{room.title.inspect}"
      end

      rooms
    end

    def ping_rows
      readings = fetch_readings
      rows = FEED_SECTIONS.flat_map { |section| Array(readings[section]) }
      warn_of_possible_feed_overflow(rows)

      rows.select { |row| row.is_a?(Hash) && row["section"] == PING_SECTION }
    end

    def room_in(row)
      ids = SUBSCRIPTION_URL.match(row["subscription_url"].to_s)
      return nil if ids.nil?

      # `bucket_name` is what Basecamp titles the conversation — "vladie +
      # Yuri Nosenko" for an unnamed Ping, the chosen name for a named one.
      Room.new(circle_id: ids[1].to_i, chat_id: ids[2].to_i, title: row["bucket_name"])
    end

    def fetch_readings
      readings = @basecamp_cli.readings(profile: @agent.profile)
      readings.is_a?(Hash) ? readings : {}
    rescue BasecampAgentConnector::Basecamp::Client::Error => error
      note_rate_limit(error)
      log "could not read @#{agent_name}'s notification feed for Pings: #{error.message}"
      {}
    end

    # The loop is the only ping thread there is; an exception that escapes a
    # poll (discovery is outside poll_room's own rescue) must cost one tick,
    # not all coverage for the rest of the session.
    def poll_loop
      until @stopping
        @wait.call(@backoff || @interval)

        begin
          poll
        rescue => error
          log "ping poll failed: #{error.message}"
        end
      end
    end

    # One rule for every fetched line, first fetch or fiftieth: already seen —
    # skip; posted since the poller started — process; otherwise it is history
    # and is marked seen silently. The last case covers both the initial
    # baseline and a pre-start line that a deletion slides back into the
    # newest-N window later — either way, history is never dispatched.
    def poll_room(room)
      lines = @basecamp_cli.chat_lines(project: room.circle_id, chat: room.chat_id, limit: FETCH_LIMIT,
        profile: @agent.profile)
      first_fetch = !@seen_line_ids.key?(room.circle_id)
      seen = @seen_line_ids[room.circle_id] ||= Set.new
      ordered = lines.sort_by { |line| line["id"].to_i }
      warn_of_possible_overflow(room, ordered, seen, first_fetch)

      ordered.each do |line|
        # A corroboration the budget refused ends the room too: each further
        # actionable line would spend more refused calls. Unprocessed lines
        # stay unseen, so the backed-off next tick picks them up.
        break if @rate_limited

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
      note_rate_limit(error)
      log "ping poll failed for #{room.title.inspect} (Ping #{room.circle_id}): #{error.message}"
    end

    # Fail toward history: a line whose timestamp is missing or unreadable is
    # baselined rather than risking a replay. The boundary itself leans the
    # other way: @started_at is floored to the second and the comparison is
    # inclusive, so a line stamped in the poller's start second counts as
    # post-start even when its created_at carries only second precision —
    # dispatching a same-second, essentially-concurrent ping beats
    # permanently dropping one sent just after start. Comparing server
    # timestamps against the local clock assumes NTP-grade sync; skew shifts
    # the history boundary by its own magnitude.
    def posted_since_start?(line)
      created_at = line["created_at"].to_s
      !created_at.empty? && Time.iso8601(created_at) >= @started_at
    rescue ArgumentError
      false
    end

    # Seen means settled. A line Basecamp did not corroborate — the
    # corroborating fetch says it is gone, or says the room is no longer
    # private to the two of them — is forgotten again so the next poll
    # retries it while it remains in the window; a deleted line simply stops
    # appearing. A fetch the CLI could not complete (even after its own
    # retries) is forgotten the same way: the next tick is this poller's
    # redelivery. A pipeline exception leaves the line seen: retrying a bug
    # every tick would only repeat it.
    def process(line, seen)
      seen << line["id"]
      seen.delete(line["id"]) unless @pipeline.process(BasecampAgentConnector::Basecamp::Event.chat_line_payload(line))
    rescue BasecampAgentConnector::Basecamp::Client::TransientError => error
      seen.delete(line["id"])
      note_rate_limit(error)
      log "could not corroborate ping line #{line["id"]}: #{error.message}; retried on the next poll"
    end

    # The fetch window is a bound: if a Ping produced more than FETCH_LIMIT
    # lines between polls (or since the poller started, for a first fetch),
    # the overflow scrolled out unseen. A full window that carries no proof of
    # continuity — no overlap with seen lines, or on a first fetch not even a
    # pre-start line — doesn't prove a gap, but say so.
    def warn_of_possible_overflow(room, ordered, seen, first_fetch)
      if ordered.length == FETCH_LIMIT && overflow_suspected?(ordered, seen, first_fetch)
        log "possible ping window overflow for #{room.title.inspect} (Ping #{room.circle_id}): " \
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

    # Discovery's own bound, and the one gap a later tick doesn't close by
    # itself: a notification feed filled to its caps by other activity can
    # push a ping row out before this poller ever saw it, and a Ping it never
    # found is never polled. It heals on the *next line in that Ping*, which
    # puts the row back at the top of `unreads`. Say so when the feed comes
    # back full with no ping row in it at all.
    def warn_of_possible_feed_overflow(rows)
      if rows.length >= FEED_WINDOW && rows.none? { |row| row.is_a?(Hash) && row["section"] == PING_SECTION }
        log "possible notification feed overflow: @#{agent_name}'s feed came back full (#{rows.length} items) " \
          "with no Pings in it; a Ping opened while it was this busy may not be found until its next line"
      end
    end

    # The API budget is shared account-wide across every concurrent CLI
    # process, so a rate-limited poll means the account is over budget, not
    # that anything here is wrong — see ChatPoller's backoff for the full
    # rationale. Each rate-limited tick doubles the effective sleep, up to
    # MAX_BACKOFF; the first tick that draws no rate-limit refusal — a
    # success, or any other failure — restores the configured cadence.
    # Logged when the delay changes, not on every backed-off tick.
    def note_rate_limit(error)
      @rate_limited ||= error.is_a?(BasecampAgentConnector::Basecamp::Client::Error) && error.rate_limited?
    end

    # Backoff only ever lengthens the delay: doubling stops at the cap, and
    # a configured interval at or above the cap never backs off at all —
    # min against a smaller cap would speed a slow poller *up*.
    def extend_backoff
      current = @backoff || @interval
      extended = [ current * 2, [ @interval, MAX_BACKOFF ].max ].min

      if extended > current
        @backoff = extended
        log "rate limited; backing off ping polls to #{extended}s"
      end
    end

    def reset_backoff
      log "no longer rate limited; resuming #{@interval}s ping polls" if @backoff
      @backoff = nil
    end

    def agent_name
      @agent.name || @agent.profile
    end

    def log(message)
      @logger.puts message
    end
end
