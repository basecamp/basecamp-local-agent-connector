require "set"
require "time"

# Boost coverage. Basecamp never delivers boosts by webhook — in bc3 a Boost
# is not a Recording and creates no Event, so no webhook can ever carry one.
# The one place Basecamp reports a boost is the boostee's own received-boosts
# feed (`/my/boosts.json`, the report behind the "You've got Boosts!"
# notification), so the only way to hear a boost on the agent's work is to
# poll that feed as the agent. On an interval the newest page of the feed is
# fetched, and every not-yet-seen boost is synthesized into a boost-kind event
# and fed through its own Pipeline instance with the same authorizer
# pre-filter, corroborating re-fetch, authoritative re-check, and STDOUT
# funnel as webhook deliveries. The feed is account-wide (notifications are
# not project-scoped), so a boost triggers wherever the agent's boosted work
# lives — the bound is the agent's identity, not the watched-project list.
#
# History is never dispatched: a boost that predates the poller is marked seen
# without being processed — on the first successful fetch (so connecting never
# replays the backlog) and on any later fetch that slides an old boost back
# into the newest-page window. Boosts received since the poller started always
# process, even when the first successful fetch comes late (a startup blip),
# so a delayed baseline doesn't swallow them. Seen ids accumulate one integer
# per boost for the session — small enough to keep unpruned. Boosts are
# immutable, so there is no edit case to consider.
class BasecampAgentConnector::Basecamp::BoostPoller
  DEFAULT_INTERVAL = 60

  # bc3's my/boosts feed is geared-paginated and only the first page is
  # fetched; its first gear carries the newest 15 boosts (verified against
  # production). The server owns that number — this is a hint for the
  # overflow warning, not a request parameter.
  FEED_WINDOW = 15

  def initialize(basecamp_cli:, pipeline:, agent:, interval: DEFAULT_INTERVAL, logger: $stderr,
    wait: ->(seconds) { sleep seconds }, clock: -> { Time.now })
    @basecamp_cli = basecamp_cli
    @pipeline = pipeline
    @agent = agent
    @interval = interval
    @logger = logger
    @wait = wait
    @clock = clock
    @seen_boost_ids = Set.new
    # Floored to the whole second because feed timestamps may carry only
    # second precision: comparing a sub-second start against a truncated
    # created_at would misfile a boost landing just after start as history
    # and drop it for good. See received_since_start?.
    @started_at = @clock.call.floor
    @stopping = false
  end

  # Nothing is fetched or emitted until the poll thread's first pass, one
  # interval later — so nothing can land on the funnel before the connector
  # has reported readiness and its consumer is watching. A boost received in
  # the meantime is not lost: post-start boosts process even when the first
  # fetch is the one that sees them.
  def start
    @thread = Thread.new { poll_loop }
  end

  def stop
    @stopping = true

    if @thread
      @thread.kill
      # Bounded, not guaranteed: a kill lands between CLI calls instantly, but
      # a thread mid-subprocess dies only when the child returns. The process
      # is tearing down anyway, so make any residue visible rather than block.
      log "boost poll thread did not stop within 5s" if @thread.join(5).nil?
      @thread = nil
    end
  end

  # One rule for every fetched boost, first fetch or fiftieth: already seen —
  # skip; received since the poller started — process; otherwise it is history
  # and is marked seen silently. The last case covers both the initial
  # baseline and a pre-start boost that deletions slide back into the
  # newest-page window later — either way, history is never dispatched.
  def poll
    return if @stopping

    boosts = @basecamp_cli.received_boosts(profile: @agent.profile)
    ordered = boosts.sort_by { |boost| boost["id"].to_i }
    warn_of_possible_overflow(ordered)

    ordered.each do |boost|
      if @seen_boost_ids.include?(boost["id"])
        # already handled
      elsif received_since_start?(boost)
        process(boost)
      else
        @seen_boost_ids << boost["id"]
      end
    end
  rescue BasecampAgentConnector::Basecamp::Client::Error => error
    log "boost poll failed: #{error.message}"
  end

  private
    # The loop is the only boost thread there is; an exception that escapes a
    # poll (a pipeline bug, say — CLI failures are already rescued closer in)
    # must cost one tick, not all coverage for the rest of the session.
    def poll_loop
      until @stopping
        @wait.call(@interval)

        begin
          poll
        rescue => error
          log "boost poll failed: #{error.message}"
        end
      end
    end

    # Fail toward history: a boost whose timestamp is missing or unreadable is
    # baselined rather than risking a replay. The boundary itself leans the
    # other way: @started_at is floored to the second and the comparison is
    # inclusive, so a boost stamped in the poller's start second counts as
    # post-start even when its created_at carries only second precision.
    # Comparing server timestamps against the local clock assumes NTP-grade
    # sync; skew shifts the history boundary by its own magnitude.
    def received_since_start?(boost)
      created_at = boost["created_at"].to_s
      !created_at.empty? && Time.iso8601(created_at) >= @started_at
    rescue ArgumentError
      false
    end

    # Seen means settled. A boost the pipeline could not corroborate — the
    # feed re-fetch failed, which a transient API or CLI blip can cause as
    # easily as a deletion — is forgotten again so the next poll retries it
    # while it remains in the feed; a deleted boost simply stops appearing.
    # A pipeline exception leaves the boost seen: retrying a bug every tick
    # would only repeat it.
    def process(boost)
      @seen_boost_ids << boost["id"]
      @seen_boost_ids.delete(boost["id"]) unless @pipeline.process(BasecampAgentConnector::Basecamp::Event.boost_payload(boost))
    end

    # The feed's first page is a bound: if the agent received more boosts than
    # one page holds between polls (or since the poller started, for a first
    # fetch), the overflow scrolled out unseen. A full page that carries no
    # proof of continuity — no overlap with seen boosts, or on a first fetch
    # not even a pre-start boost — doesn't prove a gap, but say so.
    def warn_of_possible_overflow(ordered)
      if ordered.length >= FEED_WINDOW && overflow_suspected?(ordered)
        log "possible boost feed overflow: every fetched boost is new; " \
          "boosts beyond the newest #{ordered.length} may have been missed"
      end
    end

    def overflow_suspected?(ordered)
      if @seen_boost_ids.empty?
        received_since_start?(ordered.first)
      else
        ordered.none? { |boost| @seen_boost_ids.include?(boost["id"]) }
      end
    end

    def log(message)
      @logger.puts message
    end
end
