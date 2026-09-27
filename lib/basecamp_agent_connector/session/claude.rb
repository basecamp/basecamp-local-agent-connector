require "json"
require "time"

# The Claude Code CLI, as much of it as dispatching sessions needs.
#
# Two things about it shape this class, both established against the real CLI
# rather than assumed:
#
#   1. `--background` picks the session's id itself and *ignores* `--session-id`
#      ("warning: --bg manages the session id"). So the id cannot be chosen up
#      front; it has to be read back. The id is printed on a line meant for a
#      human — `backgrounded · 1e9694b6 · Re: a card`, wrapped in colour codes —
#      and the short form it prints is the first segment of the session's full
#      uuid.
#   2. `--resume` given that short id starts a *copy* under a new id, and says
#      so: "To continue a session under its own id, pass its full session id".
#      A copy would silently give one card two sessions, which is the exact
#      failure dispatching per task exists to prevent — so the full uuid is
#      what gets stored, and it is looked up once, at spawn, while the session
#      is certain to be listed.
class BasecampAgentConnector::Session::Claude
  EXECUTABLE = "claude".freeze

  # `claude agents --json` reports two different things per session, and the
  # difference matters here. `state` is the lifecycle -- working, blocked, done.
  # `status` is what the session is doing *right now*, and it is reported only
  # while the session is resident: `busy` or `idle`, absent once it is gone.
  BUSY_STATES = %w[working].freeze
  BUSY_STATUS = "busy".freeze

  ANSI = /\e\[[0-9;]*m/
  # The separator is matched with `\W+`, not `\D+`: a short id beginning with a
  # hex letter is itself non-digit, so `\D+` consumed that first character and
  # the capture came back one short -- `c082afb6` read as `082afb6`, matching no
  # session, leaving the card unresumable and its follow-up comments undelivered.
  BACKGROUNDED = /backgrounded\W+([0-9a-f]{6,})/

  # How long to keep asking the CLI for the new session's full id. It is
  # normally listed at once; this exists so a slow machine costs a few hundred
  # milliseconds rather than a session that can never be continued.
  RESOLVE_ATTEMPTS = 12
  RESOLVE_DELAY = 0.25

  # How long to wait for a stopped session to exit before resuming it: up to
  # ten seconds, polled. The slowest teardown seen so far took under one.
  SETTLE_ATTEMPTS = 40
  SETTLE_DELAY = 0.25

  # How long after its last turn ended a session reported `busy` is believed.
  # The CLI's `status` can stick at `busy` after a turn has finished: a card
  # sat seven hours with three comments held for it, its transcript ending in
  # the turn's `turn_duration` at 11:17 and nothing after. A turn that really is
  # running writes to the transcript as it goes, so a finished turn followed by
  # silence is the stuck flag, not work. The margin is generous because a turn
  # can end with a background task still running, which the CLI rightly counts
  # as busy and which stopping the session would kill.
  TURN_OVER_GRACE = 30 * 60

  # How much of a transcript's end is read to find its last turn. Only the
  # bookkeeping written after a turn ends has to fit; a few KB in practice.
  TRANSCRIPT_TAIL_BYTES = 256 * 1024

  # Records that are the conversation itself. Everything else in a transcript --
  # cost, titles, modes, the last prompt -- is bookkeeping written around turns.
  CONVERSATION_TYPES = %w[user assistant].freeze
  TURN_ENDED = "turn_duration".freeze

  # `session_id` is nil when the spawn failed, or when it succeeded but the id
  # could not be read back — a running session that cannot be continued, which
  # the dispatcher records and retries resolving later rather than discarding.
  Spawned = Data.define(:session_id, :short_id, :result) do
    def success?
      result.success?
    end
  end

  def initialize(command_runner: BasecampAgentConnector::CommandRunner.new, executable: EXECUTABLE,
    wait: ->(seconds) { sleep seconds }, projects_dir: default_projects_dir, clock: -> { Time.now })
    @command_runner = command_runner
    @executable = executable
    @wait = wait
    @projects_dir = projects_dir
    @clock = clock
  end

  # Refuses to start rather than discovering at the first mention that there is
  # nothing to dispatch to — by which time a requester has been boosted and is
  # waiting on a reply nobody is writing.
  def available?
    run("--version").success?
  rescue Errno::ENOENT, SystemCallError
    false
  end

  # Starts a session and returns immediately; the work happens in that session,
  # not here.
  def spawn(name:, prompt:, cwd:, permission_mode: nil, model: nil)
    arguments = [ "--background", "--name", name ]
    arguments += [ "--permission-mode", permission_mode ] unless permission_mode.nil?
    arguments += [ "--model", model ] unless model.nil?

    result = run(*arguments, prompt, chdir: cwd)
    return Spawned.new(session_id: nil, short_id: nil, result: result) unless result.success?

    short_id = short_id_in(result.stdout)
    Spawned.new(session_id: short_id && resolve_session_id(short_id), short_id: short_id, result: result)
  end

  # The full uuid behind a short id, which is what `--resume` needs. Polled
  # briefly because a session that has just been spawned may not be listed on
  # the first ask.
  def resolve_session_id(short_id)
    RESOLVE_ATTEMPTS.times do |attempt|
      found = sessions&.find { |session| session["id"] == short_id }
      return found["sessionId"] if found

      @wait.call RESOLVE_DELAY if attempt < RESOLVE_ATTEMPTS - 1
    end

    nil
  end

  # Continues an existing session, keeping its id and everything in it.
  #
  # Only valid once the session is no longer resident, and only with the full
  # uuid — see the note at the top of this class for what each shortcut costs.
  def resume(session_id:, prompt:, cwd:)
    run("--background", "--resume", session_id, prompt, chdir: cwd)
  end

  # A resident session — even one that has finished its turn and reads as
  # `done` — must be stopped before it can be continued in place. Its
  # conversation survives the stop; only the process goes.
  #
  # A failed stop is expected when the session turns out not to be resident —
  # that is the whole reason to stop first when residency is unknown — and then
  # resuming is safe. But a stop that failed on a session still resident would
  # make the resume fork it. So after a failed stop, resume only on a definite
  # "not listed"; otherwise hand back the failed stop and leave the message for
  # a later attempt.
  #
  # `claude stop` returns once the stop is requested, not once the session has
  # gone. Tearing down takes a moment -- longer when it was running a dev server
  # or a test suite -- and a resume issued inside that window finds the session
  # still resident and copies it under a new id instead of continuing it. The
  # daemon log shows it five times in five days, the copy claimed between 14 and
  # 573 ms before the original finished dying. So the resume waits for the exit,
  # and gives up rather than guess: a continue that fails leaves the message
  # queued for the next flush, which only costs time, where a fork costs a
  # second agent on the card.
  def stop_then_resume(session_id:, short_id:, prompt:, cwd:)
    stopped = stop(short_id)
    return stopped unless stopped.success? || resident?(session_id) == false
    return still_shutting_down(short_id) unless exited?(session_id)

    resume(session_id: session_id, prompt: prompt, cwd: cwd)
  end

  # The short id a resume actually continued, read off the line the CLI prints.
  # A resume that forked names a different session from the one it was given.
  def continued_as(result)
    short_id_in(result.stdout)
  end

  def stop(short_id)
    run("stop", short_id)
  end

  # `working`, `blocked`, `done`, or nil when the CLI no longer lists it —
  # which is not an error: a session that has exited can still be resumed from
  # its history.
  def state(session_id)
    session(session_id)&.fetch("state", nil)
  end

  # Stopping a session that is mid-work discards that work, so a caller that
  # wants to deliver a message has to know the difference.
  #
  # The question is what the session is *doing*, which `status` answers and
  # `state` does not. A session can sit at `state: working` while `status` says
  # `idle` -- resident, but between turns or finished and not yet reaped. It is
  # not busy, and holding a message for it stalls the card for as long as the
  # process happens to linger.
  #
  # `status` is absent once the session is no longer resident, and a dead
  # session is not busy either: the CLI leaves `state` at `working` when one
  # dies mid-turn, so that case falls through to asking the process directly.
  #
  # A `busy` status is checked against the session's transcript, because the
  # CLI has been seen to leave it set long after the turn ended -- see
  # TURN_OVER_GRACE.
  #
  # `nil` when the CLI could not be asked. That is not "not busy": a caller
  # that read it as idle would stop a session that may be mid-work.
  def busy?(session_id)
    listed = sessions
    return nil if listed.nil?

    record = listed.find { |session| session["sessionId"] == session_id }
    return false unless record && BUSY_STATES.include?(record["state"])

    status = record["status"]
    return status == BUSY_STATUS && !turn_long_over?(session_id) unless status.nil?

    running? record["pid"]
  end

  # Whether the CLI still lists this session, so it is resident and has to be
  # stopped before it can be continued in place. `nil` means the CLI could not
  # be asked -- the caller is left to decide what not knowing is worth, because
  # the two answers are not equally safe to guess at.
  def resident?(session_id)
    listed = sessions
    return nil if listed.nil?

    listed.any? { |session| session["sessionId"] == session_id }
  end

  def session(session_id)
    sessions&.find { |session| session["sessionId"] == session_id }
  end

  # Includes sessions that have already finished, so a card commented on
  # tomorrow finds yesterday's session rather than opening a second one.
  # `nil` when the CLI could not be asked, which is not the same as an empty
  # list and must not be flattened into one: callers decide what a question
  # they could not get an answer to means for them.
  def sessions
    result = run("agents", "--json", "--all")
    return nil unless result.success?

    parsed = JSON.parse(result.stdout)
    parsed.is_a?(Array) ? parsed : []
  rescue JSON::ParserError
    nil
  end

  private
    def default_projects_dir
      File.join(ENV.fetch("CLAUDE_CONFIG_DIR", File.join(Dir.home, ".claude")), "projects")
    end

    # Whether the session's last turn ended at least TURN_OVER_GRACE ago with
    # nothing said since. Anything that cannot be read -- no transcript, a
    # transcript whose tail holds no turn -- is "no", leaving the CLI's word
    # standing: overruling it on a guess would stop a session mid-work.
    def turn_long_over?(session_id)
      ended = last_turn_end(transcript_of(session_id))
      !ended.nil? && @clock.call - ended >= TURN_OVER_GRACE
    end

    # Transcripts live under a directory named for the session's working
    # directory, which moves when a session enters a worktree, so it is found
    # by its id rather than by where it was started.
    def transcript_of(session_id)
      Dir.glob(File.join(@projects_dir, "*", "#{session_id}.jsonl")).max_by { |path| File.mtime(path) }
    rescue SystemCallError
      nil
    end

    # When the last turn ended, or nil if the transcript's last conversation is
    # not a finished turn -- a turn still running ends in a tool call or a
    # result, not in `turn_duration`.
    def last_turn_end(path)
      return nil if path.nil?

      tail(path).lines.reverse_each do |line|
        record = JSON.parse(line) rescue next
        next unless record.is_a?(Hash)
        return nil if CONVERSATION_TYPES.include?(record["type"])
        next unless record["type"] == "system" && record["subtype"] == TURN_ENDED

        return Time.iso8601(record["timestamp"].to_s) rescue nil
      end

      nil
    end

    # The first line of a tail read mid-file is partial; it fails to parse and
    # is skipped like any other unreadable line.
    def tail(path)
      File.open(path, "rb") do |file|
        file.seek([ file.size - TRANSCRIPT_TAIL_BYTES, 0 ].max)
        file.read.force_encoding(Encoding::UTF_8).scrub
      end
    rescue SystemCallError
      ""
    end

    # Gone from the CLI's view of what is running: no longer listed, or listed
    # without a `status`, which the CLI reports only while a session is
    # resident. A listing that cannot be read counts as not yet -- resuming on a
    # guess is exactly how a card ends up with two sessions.
    def exited?(session_id)
      SETTLE_ATTEMPTS.times do |attempt|
        listed = sessions
        unless listed.nil?
          record = listed.find { |session| session["sessionId"] == session_id }
          return true if record.nil? || record["status"].nil?
        end

        @wait.call SETTLE_DELAY if attempt < SETTLE_ATTEMPTS - 1
      end

      false
    end

    def still_shutting_down(short_id)
      BasecampAgentConnector::CommandRunner::Result.new(stdout: "",
        stderr: "session #{short_id} was still shutting down after the stop, so it was not resumed yet", exit_status: 1)
    end

    # Whether the pid the CLI reported still belongs to a live process. Signal
    # 0 delivers nothing, it only asks. `EPERM` means the process is there but
    # belongs to somebody else, which still counts as alive; anything without a
    # usable pid describes nothing worth waiting for.
    def running?(pid)
      Process.kill 0, Integer(pid)
      true
    rescue Errno::EPERM
      true
    rescue Errno::ESRCH, TypeError, ArgumentError
      false
    end

    # `backgrounded · 1e9694b6 · Re: a card`, minus the colour codes. A name
    # containing hex would parse first without the `backgrounded` anchor.
    def short_id_in(stdout)
      stdout.to_s.gsub(ANSI, "")[BACKGROUNDED, 1]
    end

    # A command that could not even be started — a mapped repo that does not
    # exist (`chdir` raises), a CLI removed since startup — is a failed result
    # like any other, so callers report it rather than having it unwind past
    # them after a receipt has already told the requester somebody has it.
    def run(*arguments, chdir: nil)
      @command_runner.run(@executable, *arguments, chdir: chdir)
    rescue SystemCallError => error
      BasecampAgentConnector::CommandRunner::Result.new(stdout: "", stderr: error.message, exit_status: 127)
    end
end
