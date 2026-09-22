require "json"

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

  # `claude agents --json` reports a `state` per session. Only one of them
  # means "busy with work that stopping would throw away".
  BUSY_STATES = %w[working].freeze

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

  # `session_id` is nil when the spawn failed, or when it succeeded but the id
  # could not be read back — a running session that cannot be continued, which
  # the dispatcher records and retries resolving later rather than discarding.
  Spawned = Data.define(:session_id, :short_id, :result) do
    def success?
      result.success?
    end
  end

  def initialize(command_runner: BasecampAgentConnector::CommandRunner.new, executable: EXECUTABLE,
    wait: ->(seconds) { sleep seconds })
    @command_runner = command_runner
    @executable = executable
    @wait = wait
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
      found = sessions.find { |session| session["id"] == short_id }
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
  def stop_then_resume(session_id:, short_id:, prompt:, cwd:)
    stop(short_id)
    resume(session_id: session_id, prompt: prompt, cwd: cwd)
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
  # A session whose process is gone is not busy, whatever its state says. The
  # CLI leaves `state` at `working` when a session dies mid-turn, and believing
  # that alone holds every later message for a session that can never finish --
  # the card goes deaf, silently, and stays that way until somebody notices.
  def busy?(session_id)
    record = session(session_id)
    return false unless record && BUSY_STATES.include?(record["state"])

    running? record["pid"]
  end

  def session(session_id)
    sessions.find { |session| session["sessionId"] == session_id }
  end

  # Includes sessions that have already finished, so a card commented on
  # tomorrow finds yesterday's session rather than opening a second one.
  def sessions
    result = run("agents", "--json", "--all")
    return [] unless result.success?

    parsed = JSON.parse(result.stdout)
    parsed.is_a?(Array) ? parsed : []
  rescue JSON::ParserError
    []
  end

  private
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

    def run(*arguments, chdir: nil)
      @command_runner.run(@executable, *arguments, chdir: chdir)
    end
end
