require_relative "test_helper"

class SessionClaudeTest < Minitest::Test
  Claude = BasecampAgentConnector::Session::Claude

  # The exact line the CLI prints on a successful spawn, colour codes included.
  BACKGROUNDED = "backgrounded · \e[36m1e9694b6\e[39m · Re: a card\n" \
    "\e[2m  claude attach 1e9694b6    open in this terminal\e[22m\n"

  # The same line for a session whose id begins with a hex letter.
  HEX_LEADING_BACKGROUNDED = "backgrounded · \e[36mc082afb6\e[39m · Re: a card\n" \
    "\e[2m  claude attach c082afb6    open in this terminal\e[22m\n"

  def setup
    @runner = FakeCommandRunner.new
    @claude = Claude.new(command_runner: @runner, wait: ->(_seconds) { })
  end

  def test_spawning_names_the_session
    stub_spawn

    @claude.spawn(name: "Fix the date picker", prompt: "do the thing", cwd: "/work/bc3")

    command = @runner.commands_matching(/--background/).first.join(" ")

    assert_includes command, "--name Fix the date picker"
    assert_includes command, "do the thing"
  end

  # `--bg` manages the session id itself and warns that it is ignoring
  # `--session-id`, so asking for one would be noise that changes nothing.
  def test_spawning_does_not_try_to_choose_the_session_id
    stub_spawn

    @claude.spawn(name: "A card", prompt: "do it", cwd: "/work/bc3")

    refute_includes @runner.commands_matching(/--background/).first.join(" "), "--session-id"
  end

  # The id comes back on a line meant for a human, wrapped in colour codes.
  def test_the_short_id_is_read_back_from_the_spawn
    stub_spawn

    assert_equal "1e9694b6", @claude.spawn(name: "A card", prompt: "do it", cwd: "/work/bc3").short_id
  end

  # `--resume` needs the full uuid — the short id forks a copy — so it is
  # looked up while the session is certain to be listed.
  def test_the_full_session_id_is_resolved_from_the_short_one
    stub_spawn

    assert_equal "1e9694b6-a647-4f69-909c-a48dd37a4a2a",
      @claude.spawn(name: "A card", prompt: "do it", cwd: "/work/bc3").session_id
  end

  # Every fixture above starts with a digit, which is what hid this: a short id
  # beginning with a hex letter is itself non-digit, so a `\D+` separator ate
  # its first character and the id came back one short -- matching no session,
  # leaving the card unresumable and its follow-up comments undelivered.
  def test_a_short_id_beginning_with_a_hex_letter_is_read_back_whole
    @runner.stub "claude --background", stdout: HEX_LEADING_BACKGROUNDED
    @runner.stub "claude agents --json", stdout: JSON.generate([
      { "id" => "c082afb6", "sessionId" => "c082afb6-7f50-45f6-b3e9-ba723392afe7",
        "name" => "Re: a card", "state" => "working", "status" => "busy" }
    ])

    spawned = @claude.spawn(name: "A card", prompt: "do it", cwd: "/work/bc3")

    assert_equal "c082afb6", spawned.short_id
    assert_equal "c082afb6-7f50-45f6-b3e9-ba723392afe7", spawned.session_id
  end

  # The session is running and will reply; it just cannot be continued yet.
  # That is worth recording, not worth discarding.
  def test_an_unlistable_session_spawns_without_a_session_id
    @runner.stub "claude --background", stdout: BACKGROUNDED
    @runner.stub "claude agents --json", stdout: "[]"

    spawned = @claude.spawn(name: "A card", prompt: "do it", cwd: "/work/bc3")

    assert_predicate spawned, :success?
    assert_equal "1e9694b6", spawned.short_id
    assert_nil spawned.session_id
  end

  def test_a_refused_spawn_yields_no_ids
    @runner.stub "claude --background", stdout: "", stderr: "boom", exit_status: 1

    spawned = @claude.spawn(name: "A card", prompt: "do it", cwd: "/work/bc3")

    refute_predicate spawned, :success?
    assert_nil spawned.short_id
    assert_nil spawned.session_id
  end

  # A session belongs in the repo its task belongs to, and the connector goes
  # on serving webhooks from wherever it was launched.
  def test_spawning_runs_in_the_tasks_repo
    stub_spawn

    @claude.spawn(name: "A card", prompt: "do the thing", cwd: "/work/bc3")

    assert_equal "/work/bc3", @runner.directory_for(/--background/)
  end

  def test_optional_flags_are_left_off_when_not_given
    stub_spawn

    @claude.spawn(name: "A card", prompt: "do it", cwd: "/work/bc3")

    command = @runner.commands_matching(/--background/).first.join(" ")

    refute_includes command, "--permission-mode"
    refute_includes command, "--model"
  end

  def test_the_permission_mode_and_model_are_passed_through
    stub_spawn

    @claude.spawn(name: "A card", prompt: "do it", cwd: "/work/bc3",
      permission_mode: "acceptEdits", model: "opus")

    command = @runner.commands_matching(/--background/).first.join(" ")

    assert_includes command, "--permission-mode acceptEdits"
    assert_includes command, "--model opus"
  end

  def test_resuming_continues_the_same_session_id
    @runner.stub "claude --background --resume", stdout: "backgrounded"

    @claude.resume(session_id: "uuid-1", prompt: "and also this", cwd: "/work/bc3")

    assert_includes @runner.commands_matching(/--resume/).first.join(" "), "--resume uuid-1"
  end

  # Resuming a session that is still resident forks a copy under a new id, so
  # the stop is not optional — it is what keeps one card on one session.
  def test_stop_then_resume_stops_before_resuming
    @runner.stub "claude stop", stdout: "stopped"
    @runner.stub "claude --background --resume", stdout: "backgrounded"

    @claude.stop_then_resume(session_id: "uuid-1", short_id: "09c36f96", prompt: "carry on", cwd: "/work/bc3")

    assert_equal [ %w[claude stop 09c36f96], [ "claude", "--background", "--resume", "uuid-1", "carry on" ] ], @runner.commands
  end

  # A stop that failed on a session still listed means it is still resident,
  # and resuming it now would fork it. The failed stop is handed back instead.
  def test_a_failed_stop_on_a_session_still_listed_does_not_resume
    @runner.stub "claude stop", stderr: "could not stop", exit_status: 1
    @runner.stub "claude agents --json", stdout: JSON.generate([ { "id" => "09c36f96", "sessionId" => "uuid-1", "state" => "done" } ])

    result = @claude.stop_then_resume(session_id: "uuid-1", short_id: "09c36f96", prompt: "carry on", cwd: "/work/bc3")

    refute_predicate result, :success?
    assert_empty @runner.commands_matching(/--resume/)
  end

  # The case stopping first exists for: residency was unknown, the session
  # turns out not to be resident, so the stop fails harmlessly and the resume
  # is safe.
  def test_a_failed_stop_on_a_session_no_longer_listed_still_resumes
    @runner.stub "claude stop", stderr: "no such session", exit_status: 1
    @runner.stub "claude agents --json", stdout: "[]"
    @runner.stub "claude --background --resume", stdout: "backgrounded"

    assert_predicate @claude.stop_then_resume(session_id: "uuid-1", short_id: "09c36f96", prompt: "carry on", cwd: "/work/bc3"), :success?
    assert_equal 1, @runner.commands_matching(/--resume uuid-1/).length
  end

  def test_a_failed_stop_when_the_listing_cannot_be_read_does_not_resume
    @runner.stub "claude stop", stderr: "could not stop", exit_status: 1
    @runner.stub "claude agents --json", stdout: "", stderr: "boom", exit_status: 1

    @claude.stop_then_resume(session_id: "uuid-1", short_id: "09c36f96", prompt: "carry on", cwd: "/work/bc3")

    assert_empty @runner.commands_matching(/--resume/)
  end

  # Not knowing is not "not busy": read as idle, the dispatcher would stop a
  # session that may be mid-work.
  def test_busy_is_unknown_when_the_listing_cannot_be_read
    @runner.stub "claude agents --json", stdout: "", stderr: "boom", exit_status: 1

    assert_nil @claude.busy?("uuid-1")
  end

  # A command that cannot even start is a failed result, not an exception that
  # unwinds past the caller after a receipt has already been posted.
  def test_a_command_that_cannot_start_is_a_failed_result
    unstartable = Object.new
    def unstartable.run(*, chdir: nil)
      raise Errno::ENOENT, chdir.to_s
    end

    spawned = Claude.new(command_runner: unstartable).spawn(name: "A card", prompt: "do it", cwd: "/no/such/repo")

    refute_predicate spawned, :success?
    assert_includes spawned.result.stderr, "/no/such/repo"
  end

  def test_reading_a_sessions_state
    @runner.stub "claude agents --json", stdout: agents_json

    assert_equal "working", @claude.state("uuid-1")
    assert_equal "done", @claude.state("uuid-2")
  end

  # A session the CLI no longer lists is not an error: its conversation
  # survives and can still be resumed.
  def test_an_unlisted_session_has_no_state
    @runner.stub "claude agents --json", stdout: agents_json

    assert_nil @claude.state("uuid-absent")
  end

  # Only work-in-progress is worth protecting. A session that has finished its
  # turn is still resident but has nothing to lose.
  def test_only_a_working_session_counts_as_busy
    @runner.stub "claude agents --json", stdout: agents_json

    assert @claude.busy?("uuid-1")
    refute @claude.busy?("uuid-2")
    refute @claude.busy?("uuid-3")
    refute @claude.busy?("uuid-absent")
  end

  # The bug this guards: a session can sit at `state: working` while `status`
  # says `idle` -- resident, but between turns or simply finished and not yet
  # reaped. Its process is alive, so liveness cannot answer the question, and a
  # message held for it waits as long as that process happens to linger.
  def test_a_resident_session_that_is_idle_is_not_busy
    @runner.stub "claude agents --json", stdout: JSON.generate([
      { "id" => "uuid-1"[0, 8], "sessionId" => "uuid-1", "name" => "A card",
        "state" => "working", "status" => "idle", "pid" => Process.pid }
    ])

    refute @claude.busy?("uuid-1")
  end

  def test_a_resident_session_that_is_working_is_busy
    @runner.stub "claude agents --json", stdout: JSON.generate([
      { "id" => "uuid-1"[0, 8], "sessionId" => "uuid-1", "name" => "A card",
        "state" => "working", "status" => "busy", "pid" => Process.pid }
    ])

    assert @claude.busy?("uuid-1")
  end

  # `status` is reported only while the session is resident. Without it there is
  # nothing to read but the process, and a session that died mid-turn keeps
  # `state: working` for good -- so the card would go deaf, silently.
  def test_without_a_status_a_gone_process_is_not_busy
    @runner.stub "claude agents --json", stdout: JSON.generate([
      { "id" => "uuid-1"[0, 8], "sessionId" => "uuid-1", "name" => "A card",
        "state" => "working", "pid" => reaped_pid }
    ])

    refute @claude.busy?("uuid-1")
  end

  def test_without_a_status_a_live_process_is_busy
    @runner.stub "claude agents --json", stdout: JSON.generate([
      { "id" => "uuid-1"[0, 8], "sessionId" => "uuid-1", "name" => "A card",
        "state" => "working", "pid" => Process.pid }
    ])

    assert @claude.busy?("uuid-1")
  end

  def test_without_a_status_or_a_pid_nothing_is_busy
    @runner.stub "claude agents --json", stdout: JSON.generate([
      { "id" => "uuid-1"[0, 8], "sessionId" => "uuid-1", "name" => "A card",
        "state" => "working" }
    ])

    refute @claude.busy?("uuid-1")
  end

  # Finished sessions are included, so a card commented on tomorrow finds
  # yesterday's session rather than opening a second one.
  def test_finished_sessions_are_listed
    @runner.stub "claude agents --json", stdout: agents_json

    assert_equal 3, @claude.sessions.length
    assert_includes @runner.commands_matching(/agents/).first, "--all"
  end

  # A question that went unanswered is not an answer of "none". Flattening the
  # two is what let a resident session be resumed in place and forked -- so an
  # unreadable listing says it does not know, and residency says so too.
  def test_unusable_output_reads_as_unknown
    @runner.stub "claude agents --json", stdout: "not json at all"

    assert_nil @claude.sessions
    assert_nil @claude.state("uuid-1")
    assert_nil @claude.resident?("uuid-1")
  end

  def test_a_failed_listing_reads_as_unknown
    @runner.stub "claude agents --json", stdout: "", stderr: "boom", exit_status: 1

    assert_nil @claude.sessions
    assert_nil @claude.resident?("uuid-1")
  end

  # An empty list is a real answer, and a different one.
  def test_an_empty_listing_reads_as_not_resident
    @runner.stub "claude agents --json", stdout: "[]"

    assert_empty @claude.sessions
    refute @claude.resident?("uuid-1")
  end

  def test_a_listed_session_is_resident
    @runner.stub "claude agents --json", stdout: agents_json

    assert @claude.resident?("uuid-1")
  end

  def test_availability_follows_the_cli
    @runner.stub "claude --version", stdout: "2.1.278 (Claude Code)"

    assert_predicate @claude, :available?
  end

  def test_an_absent_cli_is_unavailable
    @runner.stub "claude --version", stdout: "", stderr: "not found", exit_status: 127

    refute_predicate @claude, :available?
  end

  private
    def stub_spawn
      @runner.stub "claude --background", stdout: BACKGROUNDED
      @runner.stub "claude agents --json", stdout: JSON.generate([
        { "id" => "1e9694b6", "sessionId" => "1e9694b6-a647-4f69-909c-a48dd37a4a2a",
          "name" => "Re: a card", "state" => "working", "status" => "busy" }
      ])
    end

    # A pid that is certainly not running: one we started and waited on. Picking
    # a number out of the air would risk naming a live process.
    def reaped_pid
      pid = Process.spawn("true", out: File::NULL, err: File::NULL)
      Process.wait pid
      pid
    end

    def agents_json
      JSON.generate([
        { "id" => "uuid-1"[0, 8], "sessionId" => "uuid-1", "name" => "A card", "state" => "working",
          "status" => "busy", "pid" => Process.pid },
        { "id" => "uuid-2"[0, 8], "sessionId" => "uuid-2", "name" => "Another card", "state" => "done", "status" => "idle" },
        { "id" => "uuid-3"[0, 8], "sessionId" => "uuid-3", "name" => "A third", "state" => "blocked", "status" => "idle" }
      ])
    end
end

class SessionDispatchingEmitterTest < Minitest::Test
  # The STDOUT line is what a watching session reads, and it is written before
  # anything is dispatched — so turning dispatch on never costs the stream an
  # event, however the dispatch goes.
  def test_the_event_is_printed_and_then_dispatched
    output = StringIO.new
    dispatched = []
    emitter = build(output, ->(event) { dispatched << event })

    emitter.emit event

    assert_equal 99001, JSON.parse(output.string)["event_id"]
    assert_equal 99001, dispatched.first["event_id"]
  end

  def test_the_line_is_written_even_when_the_dispatcher_blows_up
    output = StringIO.new
    emitter = build(output, ->(_event) { raise "boom" })

    assert_raises(RuntimeError) { emitter.emit event }
    assert_equal 99001, JSON.parse(output.string)["event_id"]
  end

  FakeDispatcher = Struct.new(:block) do
    def dispatch(event)
      block.call event
    end
  end

  private
    def build(output, dispatch)
      BasecampAgentConnector::Session::DispatchingEmitter.new(
        inner: BasecampAgentConnector::Emitter.new(output: output),
        dispatcher: FakeDispatcher.new(dispatch))
    end

    def event
      BasecampAgentConnector::Basecamp::Event.from_payload(sample_payload)
    end
end
