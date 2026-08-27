require "test_helper"

class ChatPollerTest < Minitest::Test
  def setup
    @operator = operator_identity
    @agent = agent_identity
    @output = StringIO.new
    @logs = StringIO.new
  end

  def test_first_fetch_is_a_baseline_and_never_replays_history
    runner = FakeCommandRunner.new
    runner.stub "chat list", stdout: envelope([ chat_hash ])
    runner.stub "chat messages", stdout: envelope([ chat_line ])

    poller(runner, clock: -> { Time.utc(2026, 6, 28, 13, 0, 0) }).poll

    assert_empty @output.string
    assert_empty runner.commands_matching(/chat line /)
  end

  def test_emits_a_new_line_mentioning_the_agent_by_the_operator
    runner = corroborating_runner
    poller = poller(runner)

    poller.poll
    poller.poll

    emitted = JSON.parse(@output.string)
    assert_equal 1, @output.string.lines.length
    assert_equal 91001, emitted["event_id"]
    assert_equal "chat_lines_rich_text_created", emitted["kind"]
    assert_equal "https://3.basecamp.com/000/buckets/222/chats/333@91001", emitted["recording"]["app_url"]
    assert_equal "Chat::Transcript", emitted["recording"]["parent"]["type"]
  end

  def test_does_not_reprocess_a_seen_line
    runner = corroborating_runner
    poller = poller(runner)

    3.times { poller.poll }

    assert_equal 1, @output.string.lines.length
  end

  def test_ignores_a_line_from_an_unauthorized_author
    stranger = { "id" => 400, "name" => "Sam", "email_address" => "sam@elsewhere.net" }
    runner = FakeCommandRunner.new
    runner.stub "chat list", stdout: envelope([ chat_hash ])
    runner.stub "chat messages", stdout: envelope([]), once: true
    runner.stub "chat messages", stdout: envelope([ chat_line("creator" => stranger) ])
    poller = poller(runner)

    poller.poll
    poller.poll

    assert_empty @output.string
    assert_empty runner.commands_matching(/chat line /)
  end

  def test_ignores_the_agents_own_line
    runner = FakeCommandRunner.new
    runner.stub "chat list", stdout: envelope([ chat_hash ])
    runner.stub "chat messages", stdout: envelope([]), once: true
    runner.stub "chat messages", stdout: \
      envelope([ chat_line("creator" => { "id" => 200, "name" => "Clawdito", "email_address" => "clawdito@example.com" }) ])
    poller = poller(runner)

    poller.poll
    poller.poll

    assert_empty @output.string
    assert_empty runner.commands_matching(/chat line /)
  end

  def test_corroboration_drops_a_line_basecamp_does_not_return
    runner = FakeCommandRunner.new
    runner.stub "chat list", stdout: envelope([ chat_hash ])
    runner.stub "chat messages", stdout: envelope([]), once: true
    runner.stub "chat messages", stdout: envelope([ chat_line ])
    runner.stub "chat line ", exit_status: 1, stderr: "not found"
    poller = poller(runner)

    poller.poll
    poller.poll

    assert_empty @output.string
    assert_match(/not corroborated/, @logs.string)
  end

  def test_a_transient_corroboration_failure_is_retried_on_the_next_poll
    runner = FakeCommandRunner.new
    runner.stub "chat list", stdout: envelope([ chat_hash ])
    runner.stub "chat messages", stdout: envelope([]), once: true
    runner.stub "chat messages", stdout: envelope([ chat_line ])
    runner.stub "chat line ", exit_status: 1, stderr: "502 Bad Gateway", once: true
    runner.stub "chat line ", stdout: envelope(chat_line)
    poller = poller(runner)

    poller.poll
    poller.poll
    assert_empty @output.string
    assert_match(/not corroborated/, @logs.string)

    poller.poll
    assert_equal 1, @output.string.lines.length
    assert_equal 2, runner.commands_matching(/chat line /).length

    poller.poll
    assert_equal 1, @output.string.lines.length
  end

  def test_a_line_that_reached_a_verdict_is_not_retried
    runner = FakeCommandRunner.new
    runner.stub "chat list", stdout: envelope([ chat_hash ])
    runner.stub "chat messages", stdout: envelope([]), once: true
    runner.stub "chat messages", stdout: envelope([ chat_line ])
    runner.stub "chat line ", stdout: envelope(chat_line("content" => "<div>edited away</div>"))
    poller = poller(runner)

    3.times { poller.poll }

    assert_empty @output.string
    assert_equal 1, runner.commands_matching(/chat line /).length
  end

  def test_malformed_discovery_output_is_logged_and_retried
    runner = FakeCommandRunner.new
    runner.stub "chat list", stdout: '{"data": [{"id": 333', once: true
    runner.stub "chat list", stdout: envelope([ chat_hash ])
    runner.stub "chat messages", stdout: envelope([])
    poller = poller(runner)

    poller.poll
    assert_match(/could not list chats.*malformed JSON/, @logs.string)

    poller.poll
    assert_equal 1, runner.commands_matching(/chat messages/).length
  end

  def test_the_poll_thread_survives_an_exception_escaping_a_poll
    runner = FakeCommandRunner.new
    runner.stub "chat list", stdout: envelope([ chat_hash ])
    runner.stub "chat messages", stdout: envelope([])
    ticks = Queue.new
    polled = Queue.new
    poller = poller(runner, wait: ->(_seconds) { ticks.pop })
    attempts = 0
    # start itself calls rooms once (the synchronous discovery); the second
    # call is the first one made from the thread.
    poller.define_singleton_method(:rooms) do
      attempts += 1
      polled << attempts
      raise "surprise" if attempts == 2
      super()
    end

    poller.start
    ticks << true
    ticks << true
    polled.pop until attempts >= 3

    assert_match(/chat poll failed: surprise/, @logs.string)
    assert_predicate poller.instance_variable_get(:@thread), :alive?
  ensure
    poller&.stop
  end

  def test_authoritative_recheck_drops_a_line_whose_fetched_content_lost_the_mention
    runner = FakeCommandRunner.new
    runner.stub "chat list", stdout: envelope([ chat_hash ])
    runner.stub "chat messages", stdout: envelope([]), once: true
    runner.stub "chat messages", stdout: envelope([ chat_line ])
    runner.stub "chat line ", stdout: envelope(chat_line("content" => "<div>edited away</div>"))
    poller = poller(runner)

    poller.poll
    poller.poll

    assert_empty @output.string
    assert_match(/does not target the agent/, @logs.string)
  end

  def test_a_failed_fetch_leaves_the_baseline_for_the_next_successful_poll
    runner = FakeCommandRunner.new
    runner.stub "chat list", stdout: envelope([ chat_hash ])
    runner.stub "chat messages", exit_status: 1, stderr: "boom", once: true
    runner.stub "chat messages", stdout: envelope([ chat_line ])
    poller = poller(runner, clock: -> { Time.utc(2026, 6, 28, 13, 0, 0) })

    poller.poll
    assert_match(/chat poll failed/, @logs.string)

    # First success baselines the window instead of replaying it as "new" —
    # no emit, and no corroboration fetch was even attempted.
    poller.poll
    assert_empty @output.string
    assert_empty runner.commands_matching(/chat line /)
  end

  def test_a_failed_chat_listing_is_retried_on_the_next_poll
    runner = FakeCommandRunner.new
    runner.stub "chat list", exit_status: 1, stderr: "boom", once: true
    runner.stub "chat list", stdout: envelope([ chat_hash ])
    runner.stub "chat messages", stdout: envelope([ chat_line ])
    poller = poller(runner, clock: -> { Time.utc(2026, 6, 28, 13, 0, 0) })

    poller.poll
    assert_match(/could not list chats/, @logs.string)
    assert_empty runner.commands_matching(/chat messages/)

    poller.poll
    assert_equal 1, runner.commands_matching(/chat messages/).length
  end

  def test_polls_every_chat_in_a_project
    runner = FakeCommandRunner.new
    runner.stub "chat list", stdout: envelope([ chat_hash, chat_hash("id" => 444, "title" => "Ops") ])
    runner.stub "chat messages", stdout: envelope([])

    poller(runner).poll

    polled = runner.commands_matching(/chat messages/)
    assert_equal 2, polled.length
    assert_includes polled.first.join(" "), "--room 333"
    assert_includes polled.last.join(" "), "--room 444"
  end

  def test_start_discovers_without_emitting_then_polls_on_a_thread_and_stop_ends_it
    runner = corroborating_runner
    ticks = Queue.new
    poller = poller(runner, wait: ->(_seconds) { ticks.pop })

    rooms = poller.start
    assert_equal 1, rooms.length
    # Nothing is fetched or emitted before the thread's first pass, so the
    # caller can report readiness before any event can reach the funnel.
    assert_empty runner.commands_matching(/chat messages/)

    2.times { ticks << true }
    deadline = Time.now + 2
    sleep 0.01 until @output.string.lines.length == 1 || Time.now > deadline
    assert_equal 1, @output.string.lines.length

    thread = poller.instance_variable_get(:@thread)
    poller.stop
    refute_predicate thread, :alive?

    poller.poll
    assert_equal 1, @output.string.lines.length
  end

  def test_warns_when_the_fetch_window_may_have_overflowed
    stranger = { "id" => 400, "name" => "Sam", "email_address" => "sam@elsewhere.net" }
    window = Array.new(BasecampAgentConnector::Basecamp::ChatPoller::FETCH_LIMIT) do |index|
      chat_line("id" => 92000 + index, "creator" => stranger, "content" => "<div>line #{index}</div>")
    end
    runner = FakeCommandRunner.new
    runner.stub "chat list", stdout: envelope([ chat_hash ])
    runner.stub "chat messages", stdout: envelope([]), once: true
    runner.stub "chat messages", stdout: envelope(window)
    poller = poller(runner)

    poller.poll
    poller.poll

    assert_match(/chat window overflow/, @logs.string)
  end

  def test_rediscovers_rooms_after_the_rediscovery_interval
    now = Time.now
    runner = FakeCommandRunner.new
    runner.stub "chat list", stdout: envelope([ chat_hash ])
    runner.stub "chat messages", stdout: envelope([])
    poller = poller(runner, clock: -> { now })

    poller.poll
    poller.poll
    assert_equal 1, runner.commands_matching(/chat list/).length

    now += BasecampAgentConnector::Basecamp::ChatPoller::REDISCOVER_AFTER
    poller.poll
    assert_equal 2, runner.commands_matching(/chat list/).length
  end

  def test_a_failed_refresh_keeps_the_stale_rooms_covered_and_retries_next_poll
    now = Time.now
    runner = FakeCommandRunner.new
    runner.stub "chat list", stdout: envelope([ chat_hash ]), once: true
    runner.stub "chat list", exit_status: 1, stderr: "boom", once: true
    runner.stub "chat list", stdout: envelope([ chat_hash ])
    runner.stub "chat messages", stdout: envelope([])
    poller = poller(runner, clock: -> { now })

    poller.poll
    assert_equal 1, runner.commands_matching(/chat messages/).length

    # The refresh fails: the known room stays covered.
    now += BasecampAgentConnector::Basecamp::ChatPoller::REDISCOVER_AFTER
    poller.poll
    assert_match(/could not list chats/, @logs.string)
    assert_equal 2, runner.commands_matching(/chat messages/).length

    # Retried on the very next poll, not after another whole interval...
    poller.poll
    assert_equal 3, runner.commands_matching(/chat list/).length

    # ...and once it succeeds, the refresh clock advances again.
    poller.poll
    assert_equal 3, runner.commands_matching(/chat list/).length
  end

  def test_a_late_discovered_room_processes_lines_posted_since_start
    now = Time.now
    fresh = chat_line("created_at" => (now + 10).utc.iso8601)
    runner = FakeCommandRunner.new
    runner.stub "chat list", exit_status: 1, stderr: "boom", once: true
    runner.stub "chat list", stdout: envelope([ chat_hash ])
    runner.stub "chat messages", stdout: envelope([ fresh ])
    runner.stub "chat line ", stdout: envelope(fresh)
    poller = poller(runner, clock: -> { now })

    # The room is only discovered on the second poll; the mention was posted
    # after the poller started, so its first fetch must not baseline it away.
    poller.poll
    poller.poll

    assert_equal 1, @output.string.lines.length
    assert_equal 91001, JSON.parse(@output.string)["event_id"]
  end

  def test_warns_when_a_late_rooms_first_fetch_may_have_overflowed
    now = Time.now
    stranger = { "id" => 400, "name" => "Sam", "email_address" => "sam@elsewhere.net" }
    window = Array.new(BasecampAgentConnector::Basecamp::ChatPoller::FETCH_LIMIT) do |index|
      chat_line("id" => 92000 + index, "creator" => stranger,
        "created_at" => (now + 1 + index).utc.iso8601, "content" => "<div>line #{index}</div>")
    end
    runner = FakeCommandRunner.new
    runner.stub "chat list", stdout: envelope([ chat_hash ])
    runner.stub "chat messages", stdout: envelope(window)
    poller = poller(runner, clock: -> { now })

    poller.poll

    assert_match(/chat window overflow/, @logs.string)
  end

  def test_one_projects_failing_listing_does_not_relist_healthy_projects
    now = Time.now
    runner = FakeCommandRunner.new
    runner.stub "chat list --project A", stdout: envelope([ chat_hash ])
    runner.stub "chat list --project B", exit_status: 1, stderr: "boom"
    runner.stub "chat messages", stdout: envelope([])
    poller = poller(runner, projects: [ "A", "B" ], clock: -> { now })

    poller.poll
    poller.poll

    # B is retried each poll; A was listed once and left alone until its own
    # refresh comes due.
    assert_equal 1, runner.commands_matching(/chat list --project A/).length
    assert_equal 2, runner.commands_matching(/chat list --project B/).length
  end

  def test_a_prestart_line_reentering_the_window_is_not_dispatched
    started = Time.utc(2026, 6, 28, 13, 0, 0)
    old_mention = chat_line("id" => 90000)
    fresh = chat_line("id" => 91002, "created_at" => "2026-06-28T13:00:10Z", "content" => "<div>no mention</div>")
    runner = FakeCommandRunner.new
    runner.stub "chat list", stdout: envelope([ chat_hash ])
    runner.stub "chat messages", stdout: envelope([ chat_line ]), once: true
    # A deletion slides the window back: the old mention appears alongside new traffic.
    runner.stub "chat messages", stdout: envelope([ old_mention, fresh ])
    poller = poller(runner, clock: -> { started })

    poller.poll
    poller.poll

    assert_empty @output.string
    assert_empty runner.commands_matching(/chat line /)
  end

  def test_a_line_stamped_in_the_pollers_start_second_is_not_dropped_as_history
    # The poller starts mid-second; the line, posted just after, serializes
    # with only second precision and so compares equal to the start second.
    started = Time.utc(2026, 6, 28, 13, 0, 0.5)
    boundary = chat_line("created_at" => "2026-06-28T13:00:00Z")
    runner = FakeCommandRunner.new
    runner.stub "chat list", stdout: envelope([ chat_hash ])
    runner.stub "chat messages", stdout: envelope([ boundary ])
    runner.stub "chat line ", stdout: envelope(boundary)
    poller = poller(runner, clock: -> { started })

    poller.poll

    assert_equal 1, @output.string.lines.length
    assert_equal 91001, JSON.parse(@output.string)["event_id"]
  end

  private
    # Baseline poll sees an empty room; the next poll finds the mention line,
    # corroborated by a matching `chat line` fetch.
    def corroborating_runner
      runner = FakeCommandRunner.new
      runner.stub "chat list", stdout: envelope([ chat_hash ])
      runner.stub "chat messages", stdout: envelope([]), once: true
      runner.stub "chat messages", stdout: envelope([ chat_line ])
      runner.stub "chat line ", stdout: envelope(chat_line)
      runner
    end

    # The canonical chat_line is created at 12:00; the default clock starts the
    # poller before that, so fetched lines count as live traffic. Tests about
    # history/baselining override the clock to after 12:00 instead.
    def poller(runner, projects: [ "A" ], wait: ->(_seconds) { flunk "no waiting in direct-poll tests" }, clock: -> { Time.utc(2026, 6, 28, 11, 0, 0) })
      cli = build_cli(runner)

      BasecampAgentConnector::Basecamp::ChatPoller.new \
        basecamp_cli: cli,
        pipeline: pipeline(cli),
        projects: projects,
        logger: @logs,
        wait: wait,
        clock: clock
    end

    def pipeline(cli)
      BasecampAgentConnector::Basecamp::Pipeline.new \
        authorizer: authorizer,
        agent: @agent,
        verifier: BasecampAgentConnector::Basecamp::Verifier.new(basecamp_cli: cli, agent: @agent),
        emitter: BasecampAgentConnector::Emitter.new(output: @output),
        logger: @logs
    end
end
