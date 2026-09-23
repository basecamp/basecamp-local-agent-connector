require "test_helper"

class PingPollerTest < Minitest::Test
  # The sample ping line is posted at 12:00; a poller whose clock starts before
  # that treats it as live, one starting after treats it as history.
  BEFORE_THE_LINE = Time.utc(2026, 6, 28, 11, 0, 0)
  AFTER_THE_LINE = Time.utc(2026, 6, 28, 13, 0, 0)

  READINGS = %r{api get /my/readings\.json}
  LINES = /chat messages --project 555 --room 666/
  SUBSCRIPTION = %r{api get /buckets/555/recordings/666/subscription\.json}

  def setup
    @agent = agent_identity
    @output = StringIO.new
    @logs = StringIO.new
  end

  def test_discovery_finds_a_ping_from_the_notification_feed
    runner = feed_runner
    poller = poller(runner)

    poller.poll
    rooms = poller.rooms

    assert_equal 1, rooms.length
    assert_equal 555, rooms.first.circle_id
    assert_equal 666, rooms.first.chat_id
    assert_equal "Clawdito + Operator", rooms.first.title
    # The feed is read as the agent: a Ping is readable to nobody else.
    assert_includes runner.commands_matching(READINGS).first.join(" "), "--profile clawdito"
  end

  # The row that matters is the one whose section says so. A busy inbox is
  # mostly everything else, and none of it names a room to poll.
  def test_a_row_that_is_not_a_ping_is_not_a_room
    runner = FakeCommandRunner.new
    runner.stub "api get /my/readings.json", stdout: readings_envelope(unreads: [ inbox_notification ])

    poller = poller(runner)
    poller.poll

    assert_empty poller.rooms
  end

  # The pair of ids lives in `subscription_url` and nowhere else; a row
  # without one names nothing readable, so it is passed over rather than
  # guessed at from the `app_url`.
  def test_a_ping_row_without_a_subscription_url_is_skipped
    runner = FakeCommandRunner.new
    runner.stub "api get /my/readings.json", stdout: \
      readings_envelope(unreads: [ ping_notification("subscription_url" => nil) ])

    poller = poller(runner)
    poller.poll

    assert_empty poller.rooms
  end

  def test_first_fetch_is_a_baseline_and_never_replays_history
    runner = feed_runner
    runner.stub "chat messages --project 555 --room 666", stdout: envelope([ ping_line ])

    poller(runner, clock: -> { AFTER_THE_LINE }).poll

    assert_empty @output.string
    # Baselined at the pre-filter: no corroborating re-fetch was spent.
    assert_empty runner.commands_matching(SUBSCRIPTION)
  end

  def test_emits_a_new_ping_line_from_the_operator
    runner = feed_runner
    runner.stub "chat messages --project 555 --room 666", stdout: envelope([ ping_line ])
    runner.stub "api get https://3.basecamp.com/000/buckets/555/chats/666/lines/92001.json", stdout: envelope(ping_line)
    runner.stub "api get /buckets/555/recordings/666/subscription.json", stdout: subscribers_envelope(100, 200)

    poller(runner).poll

    emitted = JSON.parse(@output.string)
    assert_equal 1, @output.string.lines.length
    assert_equal 92001, emitted["event_id"]
    assert_equal "chat_lines_rich_text_created", emitted["kind"]
    assert_equal "Circle", emitted["recording"]["bucket"]["type"]
    # The line carries no mention at all; the room is the addressing.
    assert_equal({ "mentioned" => false, "subscribed" => false, "pinged" => true }, emitted["trigger"])
  end

  # Every ping call runs as the agent: Basecamp serves a Circle to its
  # participants and answers not_found to everyone else, so asking as the
  # operator would ask about the wrong room — or about nothing.
  def test_every_ping_call_is_made_as_the_agent
    runner = feed_runner
    runner.stub "chat messages --project 555 --room 666", stdout: envelope([ ping_line ])
    runner.stub "api get https://3.basecamp.com/000/buckets/555/chats/666/lines/92001.json", stdout: envelope(ping_line)
    runner.stub "api get /buckets/555/recordings/666/subscription.json", stdout: subscribers_envelope(100, 200)

    poller(runner).poll

    [ READINGS, LINES, SUBSCRIPTION ].each do |pattern|
      commands = runner.commands_matching(pattern)
      refute_empty commands, "expected a call matching #{pattern.inspect}"
      commands.each { |command| assert_includes command.join(" "), "--profile clawdito" }
    end
  end

  def test_does_not_reprocess_a_seen_line
    runner = corroborating_runner
    poller = poller(runner)

    3.times { poller.poll }

    assert_equal 1, @output.string.lines.length
  end

  def test_ignores_a_ping_line_from_an_unauthorized_author
    stranger = { "id" => 400, "name" => "Sam", "email_address" => "sam@elsewhere.net" }
    runner = feed_runner
    runner.stub "chat messages --project 555 --room 666", stdout: envelope([ ping_line("creator" => stranger) ])

    poller(runner).poll

    assert_empty @output.string
    # Dropped at the pre-filter, before any corroborating re-fetch.
    assert_empty runner.commands_matching(SUBSCRIPTION)
  end

  # The agent's own replies land in the same conversation and are read back on
  # the next tick. The authorizer refuses the agent's own identity outright,
  # so they cost a poll and nothing else.
  def test_ignores_the_agents_own_reply
    runner = feed_runner
    runner.stub "chat messages --project 555 --room 666", stdout: \
      envelope([ ping_line("creator" => { "id" => 200, "name" => "Clawdito", "email_address" => "clawdito@example.com" }) ])

    poller(runner).poll

    assert_empty @output.string
    assert_empty runner.commands_matching(SUBSCRIPTION)
  end

  # A third participant makes it someone else's conversation too, and the
  # reply the agent posts lands in front of them. Re-read per line, so a Ping
  # that gains a person stops triggering from that moment.
  def test_a_ping_with_a_third_participant_does_not_trigger
    runner = feed_runner
    runner.stub "chat messages --project 555 --room 666", stdout: envelope([ ping_line ])
    runner.stub "api get https://3.basecamp.com/000/buckets/555/chats/666/lines/92001.json", stdout: envelope(ping_line)
    runner.stub "api get /buckets/555/recordings/666/subscription.json", stdout: subscribers_envelope(100, 200, 400)

    poller(runner).poll

    assert_empty @output.string
    assert_match(/does not target the agent/, @logs.string)
  end

  # The kind is what the poller believed; the bucket is what Basecamp records.
  # A line whose re-fetch says it lives in a project Campfire is not a ping,
  # and still owes the mention every Campfire line owes.
  def test_a_line_the_refetch_puts_in_a_campfire_is_not_a_ping
    campfire_line = ping_line("bucket" => { "id" => 222, "name" => "BC5 Calendar", "type" => "Project" })
    runner = feed_runner
    runner.stub "chat messages --project 555 --room 666", stdout: envelope([ ping_line ])
    runner.stub "api get https://3.basecamp.com/000/buckets/555/chats/666/lines/92001.json", stdout: envelope(campfire_line)

    poller(runner).poll

    assert_empty @output.string
    assert_match(/not corroborated/, @logs.string)
    # The room was never even asked about: corroboration failed first.
    assert_empty runner.commands_matching(SUBSCRIPTION)
  end

  def test_corroboration_drops_a_line_deleted_between_poll_and_dispatch
    runner = feed_runner
    runner.stub "chat messages --project 555 --room 666", stdout: envelope([ ping_line ])
    runner.stub "api get https://3.basecamp.com/000/buckets/555/chats/666/lines/92001.json", \
      exit_status: 2, stdout: error_envelope("not_found")

    poller(runner).poll

    assert_empty @output.string
    assert_match(/not corroborated/, @logs.string)
  end

  # A failure that outlasts the client's retries is forgotten, not settled:
  # the next poll — this poller's redelivery — verifies it afresh.
  def test_a_corroboration_failure_that_outlasts_the_retries_is_retried_on_the_next_poll
    runner = feed_runner
    runner.stub "chat messages --project 555 --room 666", stdout: envelope([ ping_line ])
    stub_transient_failure runner, "api get https://3.basecamp.com/000/buckets/555/chats/666/lines/92001.json"
    runner.stub "api get https://3.basecamp.com/000/buckets/555/chats/666/lines/92001.json", stdout: envelope(ping_line)
    runner.stub "api get /buckets/555/recordings/666/subscription.json", stdout: subscribers_envelope(100, 200)
    poller = poller(runner)

    poller.poll
    assert_empty @output.string
    assert_match(/could not corroborate ping line 92001: .*retried on the next poll/, @logs.string)

    poller.poll
    assert_equal 1, @output.string.lines.length
  end

  def test_a_prestart_line_entering_the_window_late_is_not_dispatched
    runner = feed_runner
    runner.stub "chat messages --project 555 --room 666", stdout: envelope([]), once: true
    runner.stub "chat messages --project 555 --room 666", stdout: \
      envelope([ ping_line("created_at" => "2026-06-28T10:59:59Z") ])
    poller = poller(runner)

    poller.poll
    poller.poll

    assert_empty @output.string
  end

  def test_a_line_in_the_pollers_start_second_is_dispatched
    runner = corroborating_runner("created_at" => "2026-06-28T11:00:00Z")

    poller(runner, clock: -> { BEFORE_THE_LINE + 0.5 }).poll

    assert_equal 1, @output.string.lines.length
  end

  def test_a_line_with_an_unreadable_timestamp_is_baselined
    runner = feed_runner
    runner.stub "chat messages --project 555 --room 666", stdout: \
      envelope([ ping_line("created_at" => "garbage"), ping_line("id" => 92002, "created_at" => nil) ])

    poller(runner).poll

    assert_empty @output.string
    assert_empty runner.commands_matching(SUBSCRIPTION)
  end

  # A Ping opened after the poller started is found on the tick that sees it,
  # and its post-start lines dispatch even on that room's first fetch.
  def test_a_ping_opened_mid_session_is_discovered_and_its_lines_dispatch
    runner = FakeCommandRunner.new
    runner.stub "api get /my/readings.json", stdout: readings_envelope(unreads: []), once: true
    runner.stub "api get /my/readings.json", stdout: readings_envelope(unreads: [ ping_notification ])
    runner.stub "chat messages --project 555 --room 666", stdout: envelope([ ping_line ])
    runner.stub "api get https://3.basecamp.com/000/buckets/555/chats/666/lines/92001.json", stdout: envelope(ping_line)
    runner.stub "api get /buckets/555/recordings/666/subscription.json", stdout: subscribers_envelope(100, 200)
    poller = poller(runner)

    # The feed named no Ping on this tick...
    poller.poll
    assert_empty poller.rooms
    # ...and names one on the next, which reads its lines at once.
    poller.poll

    assert_equal 1, poller.rooms.length
    assert_equal 1, @output.string.lines.length
    assert_match(/Found a Ping/, @logs.string)
  end

  # A quiet conversation ages out of the notification feed. Forgetting the
  # room would stop polling a conversation that is merely paused.
  def test_a_room_that_leaves_the_feed_is_still_polled
    runner = FakeCommandRunner.new
    runner.stub "api get /my/readings.json", stdout: readings_envelope(unreads: [ ping_notification ]), once: true
    runner.stub "api get /my/readings.json", stdout: readings_envelope(unreads: [])
    runner.stub "chat messages --project 555 --room 666", stdout: envelope([])
    poller = poller(runner)

    poller.poll
    poller.poll

    assert_equal 1, poller.rooms.length
    assert_equal 2, runner.commands_matching(LINES).length
  end

  # A feed the agent cannot read costs discovery for a tick, not the rooms
  # already known — and says so.
  def test_a_failed_feed_read_leaves_known_rooms_polled
    runner = FakeCommandRunner.new
    runner.stub "api get /my/readings.json", stdout: readings_envelope(unreads: [ ping_notification ]), once: true
    stub_transient_failure runner, "api get /my/readings.json"
    runner.stub "chat messages --project 555 --room 666", stdout: envelope([])
    poller = poller(runner)

    poller.poll
    poller.poll

    assert_match(/could not read @Clawdito's notification feed for Pings/, @logs.string)
    assert_equal 1, poller.rooms.length
  end

  def test_warns_of_a_possible_window_overflow_when_every_fetched_line_is_new
    stranger = { "id" => 400, "name" => "Sam", "email_address" => "sam@elsewhere.net" }
    window = Array.new(BasecampAgentConnector::Basecamp::PingPoller::FETCH_LIMIT) do |index|
      ping_line("id" => 92100 + index, "creator" => stranger)
    end
    runner = feed_runner
    runner.stub "chat messages --project 555 --room 666", stdout: envelope(window)

    poller(runner).poll

    assert_match(/possible ping window overflow/, @logs.string)
  end

  def test_warns_when_a_full_notification_feed_names_no_ping
    window = Array.new(BasecampAgentConnector::Basecamp::PingPoller::FEED_WINDOW) do |index|
      inbox_notification("id" => 4_977_300_000 + index)
    end
    runner = FakeCommandRunner.new
    runner.stub "api get /my/readings.json", stdout: readings_envelope(unreads: window)

    poller(runner).poll

    assert_match(/possible notification feed overflow/, @logs.string)
  end

  def test_the_poll_thread_survives_an_exception_escaping_a_poll
    runner = FakeCommandRunner.new
    runner.stub "api get /my/readings.json", stdout: readings_envelope
    ticks = Queue.new
    polled = Queue.new
    poller = poller(runner, wait: ->(_seconds) { ticks.pop })
    attempts = 0
    poller.define_singleton_method(:poll) do
      attempts += 1
      polled << attempts
      raise "surprise" if attempts == 1
      super()
    end

    poller.start
    ticks << true
    ticks << true
    polled.pop until attempts >= 2

    assert_match(/ping poll failed: surprise/, @logs.string)
    assert_predicate poller.instance_variable_get(:@thread), :alive?
  ensure
    poller&.stop
  end

  def test_start_discovers_but_reads_no_line_before_the_first_interval
    runner = corroborating_runner
    ticks = Queue.new
    poller = poller(runner, wait: ->(_seconds) { ticks.pop })

    rooms = poller.start

    # Discovery is synchronous, so the caller can report an accurate count...
    assert_equal 1, rooms.length
    # ...but no line is read, and nothing can beat the watcher to the funnel.
    assert_empty runner.commands_matching(LINES)

    2.times { ticks << true }
    deadline = Time.now + 2
    sleep 0.01 while @output.string.empty? && Time.now < deadline
    assert_equal 1, @output.string.lines.length

    poller.stop
    refute poller.instance_variable_get(:@thread)
  ensure
    poller&.stop
  end

  # Same account-wide budget pressure as the other pollers: a rate-limited
  # tick doubles the effective sleep, a clean one restores the cadence.
  def test_rate_limited_polls_back_off_doubling_until_a_clean_poll_resets_the_cadence
    runner = feed_runner
    runner.stub "chat messages --project 555 --room 666", exit_status: 7,       stdout: error_envelope("api_error", "rate limit exceeded"), times: 9
    runner.stub "chat messages --project 555 --room 666", stdout: envelope([])
    delays = Queue.new
    ticks = Queue.new
    poller = poller(runner, wait: ->(seconds) { delays << seconds; ticks.pop })

    poller.start
    waited = [ delays.pop ]
    4.times do
      ticks << true
      waited << delays.pop
    end

    assert_equal [ 30, 60, 120, 240, 30 ], waited
    assert_match(/no longer rate limited; resuming 30s ping polls/, @logs.string)
  ensure
    poller&.stop
  end

  def test_backoff_stops_doubling_at_the_cap
    runner = feed_runner
    runner.stub "chat messages --project 555 --room 666", exit_status: 7,       stdout: error_envelope("api_error", "rate limit exceeded")
    delays = Queue.new
    ticks = Queue.new
    poller = poller(runner, wait: ->(seconds) { delays << seconds; ticks.pop })

    poller.start
    waited = [ delays.pop ]
    5.times do
      ticks << true
      waited << delays.pop
    end

    assert_equal [ 30, 60, 120, 240, 300, 300 ], waited
  ensure
    poller&.stop
  end

  # A rate-limited corroborating re-fetch is the same budget refusing: the
  # line is forgotten for the next tick, and the tick still backs off.
  def test_a_rate_limited_corroboration_backs_off_and_retries_the_line
    runner = feed_runner
    runner.stub "chat messages --project 555 --room 666", stdout: envelope([ ping_line ])
    runner.stub "api get https://3.basecamp.com/000/buckets/555/chats/666/lines/92001.json", \
      exit_status: 7, stdout: error_envelope("api_error", "rate limit exceeded"), times: 3
    runner.stub "api get https://3.basecamp.com/000/buckets/555/chats/666/lines/92001.json", stdout: envelope(ping_line)
    runner.stub "api get /buckets/555/recordings/666/subscription.json", stdout: subscribers_envelope(100, 200)
    poller = poller(runner)

    poller.poll
    assert_empty @output.string
    assert_match(/could not corroborate ping line 92001/, @logs.string)
    assert_match(/rate limited; backing off ping polls to 60s/, @logs.string)

    poller.poll
    assert_equal 1, @output.string.lines.length
  end

  private
    def poller(runner, clock: -> { BEFORE_THE_LINE }, wait: ->(_seconds) { }, trust_authorizer: authorizer, interval: 30)
      BasecampAgentConnector::Basecamp::PingPoller.new \
        basecamp_cli: build_cli(runner),
        pipeline: pipeline(runner, trust_authorizer),
        agent: @agent,
        interval: interval,
        logger: @logs,
        wait: wait,
        clock: clock
    end

    def pipeline(runner, trust_authorizer)
      BasecampAgentConnector::Basecamp::Pipeline.new \
        authorizer: trust_authorizer,
        agent: @agent,
        verifier: BasecampAgentConnector::Basecamp::Verifier.new(basecamp_cli: build_cli(runner), agent: @agent,
          operator: operator_identity),
        emitter: BasecampAgentConnector::Emitter.new(output: @output),
        logger: @logs
    end

    # One Ping in the feed and nothing else stubbed: enough to discover a room.
    def feed_runner
      runner = FakeCommandRunner.new
      runner.stub "api get /my/readings.json", stdout: readings_envelope(unreads: [ ping_notification ])
      runner
    end

    # The whole happy path: feed, lines, corroborating re-fetch, and a room
    # holding the operator and the agent and nobody else.
    def corroborating_runner(line_overrides = {})
      line = ping_line(line_overrides)
      runner = feed_runner
      runner.stub "chat messages --project 555 --room 666", stdout: envelope([ line ])
      runner.stub "api get https://3.basecamp.com/000/buckets/555/chats/666/lines/92001.json", stdout: envelope(line)
      runner.stub "api get /buckets/555/recordings/666/subscription.json", stdout: subscribers_envelope(100, 200)
      runner
    end
end
