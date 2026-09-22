# Turns a verified event into a Claude session, one per thing of work.
#
# This is the half of the connector that replaces a watching session. Where a
# model sitting on STDOUT used to boost, resolve a repo and spawn a worker, all
# three happen here — in the same code path that verified the event, a few
# milliseconds after it arrived, whether or not anything is watching.
#
# Three things follow from having no model in the loop, and each one shows up
# below:
#
#   - Nobody can be asked. A project that maps to no repo cannot be resolved by
#     guessing, so the event is held with a reply saying so, rather than
#     dispatched into some arbitrary directory.
#   - Nobody notices a failure. A spawn that does not start posts nothing, and
#     from Basecamp that is indistinguishable from a mention that never
#     arrived — so a refused spawn is reported on the recording.
#   - Nobody can be interrupted. Stopping a session that is mid-work throws
#     that work away, so a comment arriving while its session is busy waits in
#     the registry until the session finishes, and is delivered then.
class BasecampAgentConnector::Session::Dispatcher
  DEFAULT_FLUSH_INTERVAL = 15
  DEFAULT_PERMISSION_MODE = "acceptEdits".freeze

  # Events that are not a directive: a boost is a reaction to work already
  # done, and a comment on a followed thread is context somebody else is
  # having. Neither earns a receipt boost of its own.
  UNACKED_KINDS = %w[boost_created].freeze

  def initialize(agent:, basecamp_cli:, claude: BasecampAgentConnector::Session::Claude.new,
    registry: BasecampAgentConnector::Session::Registry.new,
    repos: BasecampAgentConnector::Session::RepoResolver.new,
    permission_mode: DEFAULT_PERMISSION_MODE, model: nil,
    flush_interval: DEFAULT_FLUSH_INTERVAL, logger: $stderr)
    @agent = agent
    @basecamp_cli = basecamp_cli
    @claude = claude
    @registry = registry
    @repos = repos
    @permission_mode = permission_mode
    @model = model
    @flush_interval = flush_interval
    @logger = logger
  end

  # True when this event was taken on — dispatched, queued, or held with a reply
  # on the recording saying why (a project with no repo, a spawn that refused).
  # False means nothing was done and the event is the STDOUT stream's alone: a
  # GitHub review line, a move this agent is ignoring, or a dispatch that failed.
  def dispatch(event)
    key = BasecampAgentConnector::Session::Key.from_event(event, agent: @agent)
    return false if key.nil?
    return false unless worth_a_session?(event, key)

    acked = acknowledge(event)
    deliver(key, event, acked: acked)
  rescue StandardError => error
    # Deliberately broad. This runs on the thread handling a webhook delivery,
    # and an exception escaping here would take that thread down — leaving the
    # connector alive but quietly deaf to whatever that transport delivers
    # next. The event has already been verified and written to STDOUT, so
    # swallowing the failure costs this one dispatch and nothing else.
    log "session dispatch failed for event #{event["event_id"]}: #{error.class}: #{error.message}"
    false
  end

  # Delivers what was held for sessions that have since gone quiet. Runs on its
  # own thread because the alternative — delivering on the next event — leaves
  # a comment sitting in the registry for as long as the card stays quiet,
  # which on a card with one comment is forever.
  def start_flusher
    @flusher ||= Thread.new do
      loop do
        sleep @flush_interval
        flush
      rescue StandardError => error
        log "session flush failed: #{error.message}"
      end
    end
  end

  def stop_flusher
    @flusher&.kill
    @flusher = nil
  end

  # Each card's check, delivery and queue update happen under that card's
  # registry lock — the lock a webhook delivery takes too. Otherwise a comment
  # could continue the session between this reading it idle and resuming it,
  # and this would then stop a session that had just become busy. The queue is
  # cleared only once the continuation actually went through; one that failed
  # leaves every message waiting for the next pass.
  def flush
    @registry.queued.each do |queued|
      @registry.with(queued.key) do |entry|
        next nil if entry.nil? || entry.queue.empty?
        next nil unless @claude.busy?(entry.session_id) == false

        # Everything waiting goes in one continuation. Resuming once per queued
        # comment would stop and restart the session for each of them, and it
        # would read them in the order the restarts happened to finish.
        continued, delivered = continue(entry, entry.queue.join("\n\n---\n\n"))
        delivered ? continued.with(queue: []) : continued
      end
    end
  end

  private
    # A column move is the one trigger that may arrive about a card the agent
    # has nothing to do with: anyone's card, dragged across a board the agent
    # merely watches. So it drives a session it already has — a card mid-
    # conversation is exactly what a move is meant to push along — but opens a
    # new one only where the board says the card is the agent's, which is the
    # assignment. Everything else here was addressed to the agent by name and
    # needs no such test.
    #
    # Checked before the receipt boost, so a move the agent is going to ignore
    # does not leave a boost on the card implying somebody picked it up.
    def worth_a_session?(event, key)
      return true unless event.dig("trigger", "moved")
      return true if @registry.find(key.to_s)
      return true if event.dig("trigger", "assigned")

      log "ignored move of #{key.display_name} into #{column_title(event).inspect}: no session, and the agent is not an assignee"
      false
    end

    def column_title(event)
      event.dig("recording", "parent", "title")
    end

    # The receipt, posted before anything slow happens. It is the one Basecamp
    # write this class makes on the happy path; everything else the session
    # says, it says itself.
    #
    # Returns whether the requester can see that the mention registered — which
    # is true both when the boost landed and when none was owed. The dispatched
    # session is told, and posts a fallback only if it is false.
    def acknowledge(event)
      return true unless acknowledgeable?(event)

      url = event.dig("recording", "url")
      return true if url.nil?

      @basecamp_cli.create_boost url_or_id: url, content: ack_content(event),
        profile: @agent, event: acknowledged_event_id(event)
      true
    rescue BasecampAgentConnector::Basecamp::Client::Error => error
      log "receipt boost did not land for event #{event["event_id"]}: #{error.message}"
      false
    end

    # Every other trigger names a recording the requester wrote -- a comment, a
    # message -- and boosting that is the receipt. A move names only the card,
    # which may be weeks old and says nothing about which move was picked up.
    # The move itself is an event in the card's history, and bc3 lets those
    # carry boosts, so the receipt goes on the "moved this card to In progress"
    # line that actually asked for the work. `event_id` is that event's id.
    def acknowledged_event_id(event)
      event["event_id"] if event.dig("trigger", "moved")
    end

    def acknowledgeable?(event)
      !UNACKED_KINDS.include?(event["kind"]) && !event.dig("trigger", "subscribed")
    end

    # Deliberately plain. A watching model could read the room and pick
    # something apt; this cannot, and a fixed token that always means "received"
    # is more honest than a randomly chosen emoji pretending to be a reaction.
    def ack_content(_event)
      "👀"
    end

    def deliver(key, event, acked:)
      requester = requester_of(event)

      @registry.with(key) do |entry|
        next open(key, event, requester: requester, acked: acked) if entry.nil?

        prompt = BasecampAgentConnector::Session::Prompt.follow_up(event: event, requester: requester, agent: @agent, acked: acked)
        busy = @claude.busy?(entry.session_id)

        # Only a definite "idle" is continued now. Busy, or a listing the CLI
        # could not give, waits for the flusher: stopping a session that may be
        # mid-work would throw that work away.
        if busy != false
          hold entry, prompt, reason: busy.nil? ? "its state could not be read" : "it is busy"
        else
          continued, delivered = continue(entry, prompt)
          delivered ? continued : continued.with(queue: continued.queue + [ prompt ])
        end
      end

      true
    end

    # The first event on a thing of work: resolve where it runs, brief a new
    # session, and record it so everything after this joins it.
    def open(key, event, requester:, acked:)
      repo = @repos.resolve(event.dig("recording", "bucket", "name"))

      if repo.nil?
        hold_for_repo event
        return nil
      end

      prompt = BasecampAgentConnector::Session::Prompt.opening(
        event: event, agent: @agent, key: key, requester: requester, acked: acked)

      spawned = @claude.spawn(name: key.display_name, prompt: prompt, cwd: repo,
        permission_mode: @permission_mode, model: @model)

      unless spawned.success?
        report_failed_spawn event, detail: spawned.result.stderr.to_s.strip
        return nil
      end

      log "session #{spawned.short_id} opened for #{key.display_name} (#{key.type} #{key.id}) in #{repo}"
      log "session #{spawned.short_id} has no resolvable session id; it will run but cannot be continued yet" \
        if spawned.session_id.nil?

      BasecampAgentConnector::Session::Registry::Entry.new(
        key: key.to_s, session_id: spawned.session_id, short_id: spawned.short_id,
        name: key.display_name, repo: repo, created_at: Time.now.utc.iso8601, queue: [])
    end

    # The session is mid-work, or may be. Stopping it to say this would discard
    # whatever it is in the middle of, so the message waits for the flusher.
    def hold(entry, prompt, reason:)
      log "session #{entry.short_id}: holding activity on #{entry.name}, because #{reason}"

      entry.with(queue: entry.queue + [ prompt ])
    end

    # A resident session has to be stopped before it can be continued in place —
    # resuming a running one forks a copy under a new id, which would give the
    # card a second session and lose the point of all this. A session the CLI no
    # longer lists has nothing to stop and resumes straight from its history.
    #
    # Returns the entry to record when the lookup below filled in an id that was
    # missing, and nil otherwise.
    #
    # Returns the entry to record — `resolved` may have filled in a missing id —
    # and whether the prompt actually reached the session. Callers keep the
    # prompt queued unless it did.
    def continue(entry, prompt)
      entry = resolved(entry)

      unless entry.resumable?
        log "session #{entry.short_id} has no session id to resume yet; keeping activity on #{entry.name} queued"
        return [ entry, false ]
      end

      # The branches are not symmetric. Stopping a session that turns out not to
      # be resident costs nothing: the stop fails, the resume proceeds. Resuming
      # one that *is* resident forks it -- a copy under a new id carrying the
      # whole conversation, which is the exact failure dispatching per card
      # exists to prevent, and it announces itself as an ordinary continue.
      #
      # So only a definite "not resident" earns the plain resume. Not knowing
      # takes the safe branch, which matters most right after a restart, when
      # the CLI is least able to answer and the first event is arriving.
      result =
        if @claude.resident?(entry.session_id) == false
          @claude.resume(session_id: entry.session_id, prompt: prompt, cwd: entry.repo)
        else
          @claude.stop_then_resume(session_id: entry.session_id, short_id: entry.short_id, prompt: prompt, cwd: entry.repo)
        end

      log(result.success? ? "session #{entry.short_id} continued for #{entry.name}" \
        : "session #{entry.short_id} could not be continued, keeping it queued: #{result.stderr.to_s.strip}")

      [ entry, result.success? ]
    end

    # A spawn whose id could not be read back is retried here rather than at the
    # time: by now the session has certainly been listed, so the entry can
    # usually be repaired and the card goes on having one session.
    def resolved(entry)
      return entry if entry.resumable? || entry.short_id.nil?

      session_id = @claude.resolve_session_id(entry.short_id)
      session_id.nil? ? entry : entry.with(session_id: session_id)
    end

    # Received, but nobody is working it — which Basecamp would otherwise show
    # as an acked task in flight. Says so on the recording, as the agent.
    def hold_for_repo(event)
      say event, "Got this, but I can't tell which local repo \"#{event.dig("recording", "bucket", "name")}\" maps to, " \
        "so I haven't started. Add it to config/project_repos.toml (or tell me the repo) and mention me again."
      log "no repo mapping for project #{event.dig("recording", "bucket", "name").inspect}; held event #{event["event_id"]}"
    end

    def report_failed_spawn(event, detail:)
      say event, "Got this, but I couldn't start a session to work it#{": #{detail}" unless detail.empty?}."
      log "spawn failed for event #{event["event_id"]}: #{detail}"
    end

    # The connector's own voice on a recording, used only when there is no
    # session to speak for itself. Best effort: if this fails too, the boost is
    # still on the recording and the log has the reason.
    def say(event, body)
      target = reply_target(event)
      return if target.nil?

      @basecamp_cli.create_comment url_or_id: target, content: "<div>#{body}</div>", profile: @agent
    rescue BasecampAgentConnector::Basecamp::Client::Error => error
      log "could not post holding reply for event #{event["event_id"]}: #{error.message}"
    end

    def reply_target(event)
      recording = event["recording"] || {}

      if recording["type"] == "Comment"
        recording.dig("parent", "url") || recording.dig("parent", "app_url")
      else
        recording["url"] || recording["app_url"]
      end
    end

    def requester_of(event)
      event.dig("creator", "name") || event.dig("creator", "email_address") || "the requester"
    end

    def log(message)
      @logger.puts "[session] #{message}"
    rescue IOError, Errno::EPIPE
      nil
    end
end
