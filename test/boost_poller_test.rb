require "test_helper"

class BoostPollerTest < Minitest::Test
  # The sample boost is received at 12:00; a poller whose clock starts before
  # that treats it as live, one starting after treats it as history.
  BEFORE_THE_BOOST = Time.utc(2026, 6, 28, 11, 0, 0)
  AFTER_THE_BOOST = Time.utc(2026, 6, 28, 13, 0, 0)

  def setup
    @agent = agent_identity
    @output = StringIO.new
    @logs = StringIO.new
  end

  def test_first_fetch_is_a_baseline_and_never_replays_history
    runner = FakeCommandRunner.new
    runner.stub "api get /my/boosts.json", stdout: envelope([ received_boost ])

    poller(runner, clock: -> { AFTER_THE_BOOST }).poll

    assert_empty @output.string
    assert_equal 1, runner.commands_matching(%r{api get /my/boosts\.json}).length
  end

  def test_emits_a_new_boost_from_the_operator
    runner = FakeCommandRunner.new
    runner.stub "api get /my/boosts.json", stdout: envelope([ received_boost ])

    poller(runner).poll

    emitted = JSON.parse(@output.string)
    assert_equal 1, @output.string.lines.length
    assert_equal 88001, emitted["event_id"]
    assert_equal "boost_created", emitted["kind"]
    assert_equal "🔥", emitted["details"]["boost"]["content"]
    # The operator authorized by Person id — the agent's view of the feed
    # redacts other users' emails.
    assert_equal 100, emitted["creator"]["id"]
    assert_equal 456, emitted["recording"]["id"]
    assert_includes runner.commands_matching(%r{api get /my/boosts\.json}).first.join(" "), "--profile clawdito"
  end

  def test_does_not_reprocess_a_seen_boost
    runner = FakeCommandRunner.new
    runner.stub "api get /my/boosts.json", stdout: envelope([ received_boost ])
    poller = poller(runner)

    3.times { poller.poll }

    assert_equal 1, @output.string.lines.length
  end

  def test_ignores_a_boost_from_an_unauthorized_booster
    stranger = { "id" => 400, "name" => "Sam", "email_address" => "sam@elsewhere.net" }
    runner = FakeCommandRunner.new
    runner.stub "api get /my/boosts.json", stdout: envelope([ received_boost("booster" => stranger) ])

    poller(runner).poll

    assert_empty @output.string
    # The pre-filter dropped it before any corroborating re-fetch.
    assert_equal 1, runner.commands_matching(%r{api get /my/boosts\.json}).length
  end

  def test_ignores_the_agents_own_boost
    runner = FakeCommandRunner.new
    runner.stub "api get /my/boosts.json", stdout: \
      envelope([ received_boost("booster" => { "id" => 200, "name" => "Clawdito", "email_address" => "clawdito@example.com" }) ])

    poller(runner).poll

    assert_empty @output.string
    assert_equal 1, runner.commands_matching(%r{api get /my/boosts\.json}).length
  end

  def test_corroboration_drops_a_boost_that_left_the_feed
    runner = FakeCommandRunner.new
    runner.stub "api get /my/boosts.json", stdout: envelope([ received_boost ]), once: true
    runner.stub "api get /my/boosts.json", stdout: envelope([])
    poller = poller(runner)

    poller.poll
    poller.poll

    assert_empty @output.string
    assert_match(/not corroborated/, @logs.string)
  end

  # One lost keyring probe on the corroborating re-fetch is absorbed by the
  # client's retry: the boost settles on this poll, nothing is logged as
  # uncorroborated, and later polls see it as seen.
  def test_a_transient_corroboration_failure_is_retried_within_the_poll
    runner = FakeCommandRunner.new
    runner.stub "api get /my/boosts.json", stdout: envelope([ received_boost ]), once: true
    runner.stub "api get /my/boosts.json", exit_status: 1, stderr: "502 Bad Gateway", once: true
    runner.stub "api get /my/boosts.json", stdout: envelope([ received_boost ])
    poller = poller(runner)

    poller.poll
    assert_equal 1, @output.string.lines.length
    refute_match(/not corroborated/, @logs.string)

    poller.poll
    assert_equal 1, @output.string.lines.length
  end

  # A failure that outlasts the client's retries is forgotten, not settled:
  # the next poll — this poller's redelivery — verifies it afresh.
  def test_a_corroboration_failure_that_outlasts_the_retries_is_retried_on_the_next_poll
    runner = FakeCommandRunner.new
    runner.stub "api get /my/boosts.json", stdout: envelope([ received_boost ]), once: true
    stub_transient_failure runner, "api get /my/boosts.json"
    runner.stub "api get /my/boosts.json", stdout: envelope([ received_boost ])
    poller = poller(runner)

    poller.poll
    assert_empty @output.string
    assert_match(/could not corroborate boost 88001: .*retried on the next poll/, @logs.string)
    refute_match(/not corroborated/, @logs.string)

    poller.poll
    assert_equal 1, @output.string.lines.length

    poller.poll
    assert_equal 1, @output.string.lines.length
  end

  def test_a_boost_that_reached_a_verdict_is_not_retried
    # A boost from an author the trust mode cannot match — here an allowlisted
    # colleague whose email the feed redacts, leaving only a Person id the
    # allowlist can't key on — is a settled drop, not a retry: later polls
    # skip it without ever re-fetching.
    colleague = { "id" => 300, "name" => "Marie", "email_address" => "m••••@•••••••.•••", "client" => false }
    runner = FakeCommandRunner.new
    runner.stub "api get /my/boosts.json", stdout: envelope([ received_boost("booster" => colleague) ])
    poller = poller(runner, trust_authorizer: authorizer(trust: :allowlist, emails: [ "marie@example.com" ]))

    3.times { poller.poll }

    assert_empty @output.string
    # One fetch per poll and no corroborating re-fetches: the drop settled at
    # the pre-filter and stayed settled.
    assert_equal 3, runner.commands_matching(%r{api get /my/boosts\.json}).length
  end

  def test_a_prestart_boost_entering_the_window_late_is_not_dispatched
    runner = FakeCommandRunner.new
    runner.stub "api get /my/boosts.json", stdout: envelope([]), once: true
    runner.stub "api get /my/boosts.json", stdout: envelope([ received_boost("created_at" => "2026-06-28T10:59:59Z") ])
    poller = poller(runner)

    poller.poll
    poller.poll

    assert_empty @output.string
    assert_equal 2, runner.commands_matching(%r{api get /my/boosts\.json}).length
  end

  def test_a_boost_in_the_pollers_start_second_is_dispatched
    runner = FakeCommandRunner.new
    runner.stub "api get /my/boosts.json", stdout: envelope([ received_boost("created_at" => "2026-06-28T11:00:00Z") ])

    poller(runner, clock: -> { BEFORE_THE_BOOST + 0.5 }).poll

    assert_equal 1, @output.string.lines.length
  end

  def test_a_boost_with_an_unreadable_timestamp_is_baselined
    runner = FakeCommandRunner.new
    runner.stub "api get /my/boosts.json", stdout: \
      envelope([ received_boost("created_at" => "garbage"), received_boost("id" => 88002, "created_at" => nil) ])

    poller(runner).poll

    assert_empty @output.string
    assert_equal 1, runner.commands_matching(%r{api get /my/boosts\.json}).length
  end

  def test_warns_of_a_possible_feed_overflow_when_every_fetched_boost_is_new
    stranger = { "id" => 400, "name" => "Sam", "email_address" => "sam@elsewhere.net" }
    window = Array.new(BasecampAgentConnector::Basecamp::BoostPoller::FEED_WINDOW) do |index|
      received_boost("id" => 88100 + index, "booster" => stranger)
    end
    runner = FakeCommandRunner.new
    runner.stub "api get /my/boosts.json", stdout: envelope(window)

    poller(runner).poll

    assert_match(/possible boost feed overflow/, @logs.string)
  end

  def test_no_overflow_warning_when_the_window_overlaps_seen_boosts
    stranger = { "id" => 400, "name" => "Sam", "email_address" => "sam@elsewhere.net" }
    window = Array.new(BasecampAgentConnector::Basecamp::BoostPoller::FEED_WINDOW) do |index|
      received_boost("id" => 88100 + index, "booster" => stranger)
    end
    runner = FakeCommandRunner.new
    runner.stub "api get /my/boosts.json", stdout: envelope(window.first(1)), once: true
    runner.stub "api get /my/boosts.json", stdout: envelope(window)
    poller = poller(runner)

    poller.poll
    poller.poll

    refute_match(/possible boost feed overflow/, @logs.string)
  end

  def test_a_failed_fetch_leaves_the_baseline_for_the_next_successful_poll
    runner = FakeCommandRunner.new
    stub_transient_failure runner, "api get /my/boosts.json", stdout: "", exit_status: 1
    runner.stub "api get /my/boosts.json", stdout: envelope([ received_boost ])
    poller = poller(runner, clock: -> { AFTER_THE_BOOST })

    poller.poll
    assert_match(/boost poll failed/, @logs.string)

    # First success baselines by time instead of replaying history as "new".
    poller.poll
    assert_empty @output.string
  end

  def test_malformed_feed_output_is_logged_and_retried
    runner = FakeCommandRunner.new
    stub_transient_failure runner, "api get /my/boosts.json", stdout: '{"data": [{"id": 88', exit_status: 0
    runner.stub "api get /my/boosts.json", stdout: envelope([ received_boost ])
    poller = poller(runner)

    poller.poll
    assert_match(/boost poll failed.*malformed JSON/, @logs.string)

    poller.poll
    assert_equal 1, @output.string.lines.length
  end

  def test_the_poll_thread_survives_an_exception_escaping_a_poll
    runner = FakeCommandRunner.new
    runner.stub "api get /my/boosts.json", stdout: envelope([])
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

    assert_match(/boost poll failed: surprise/, @logs.string)
    assert_predicate poller.instance_variable_get(:@thread), :alive?
  ensure
    poller&.stop
  end

  def test_start_fetches_nothing_before_the_first_interval_and_stop_ends_the_thread
    runner = FakeCommandRunner.new
    runner.stub "api get /my/boosts.json", stdout: envelope([ received_boost ])
    ticks = Queue.new
    poller = poller(runner, wait: ->(_seconds) { ticks.pop })

    poller.start
    # Nothing is fetched or emitted before the thread's first pass, so the
    # caller can report readiness before any event can reach the funnel.
    assert_empty runner.commands_matching(%r{api get /my/boosts\.json})

    2.times { ticks << true }
    deadline = Time.now + 2
    sleep 0.01 while @output.string.empty? && Time.now < deadline
    assert_equal 1, @output.string.lines.length

    poller.stop
    refute poller.instance_variable_get(:@thread)
  end

  # Same account-wide budget pressure as the chat poll: a rate-limited tick
  # doubles the effective sleep, a clean one restores the cadence.
  def test_rate_limited_polls_back_off_doubling_until_a_clean_poll_resets_the_cadence
    runner = FakeCommandRunner.new
    # Three rate-limited ticks, each retried through by the client (3 attempts).
    runner.stub "api get /my/boosts.json", exit_status: 7, stdout: error_envelope("api_error", "rate limit exceeded"), times: 9
    runner.stub "api get /my/boosts.json", stdout: envelope([])
    delays = Queue.new
    ticks = Queue.new
    poller = poller(runner, wait: ->(seconds) { delays << seconds; ticks.pop })

    poller.start
    waited = [ delays.pop ]
    4.times do
      ticks << true
      waited << delays.pop
    end

    assert_equal [ 15, 30, 60, 120, 15 ], waited
    assert_equal 3, @logs.string.scan(/backing off boost polls/).length
    assert_match(/no longer rate limited; resuming 15s boost polls/, @logs.string)
  ensure
    poller&.stop
  end

  def test_backoff_stops_doubling_at_the_cap
    runner = FakeCommandRunner.new
    runner.stub "api get /my/boosts.json", exit_status: 7, stdout: error_envelope("api_error", "rate limit exceeded")
    delays = Queue.new
    ticks = Queue.new
    poller = poller(runner, wait: ->(seconds) { delays << seconds; ticks.pop })

    poller.start
    waited = [ delays.pop ]
    6.times do
      ticks << true
      waited << delays.pop
    end

    assert_equal [ 15, 30, 60, 120, 240, 300, 300 ], waited
    assert_equal 5, @logs.string.scan(/backing off boost polls/).length
  ensure
    poller&.stop
  end

  # The taxonomy's dedicated rate_limit code takes the client's transient
  # path — retried through before surfacing — and still eases the poller off.
  def test_the_dedicated_rate_limit_code_backs_off_too
    runner = FakeCommandRunner.new
    runner.stub "api get /my/boosts.json", exit_status: 5, stdout: error_envelope("rate_limit", "Rate limit exceeded")
    delays = Queue.new
    ticks = Queue.new
    poller = poller(runner, wait: ->(seconds) { delays << seconds; ticks.pop })

    poller.start
    waited = [ delays.pop ]
    ticks << true
    waited << delays.pop

    assert_equal [ 15, 30 ], waited
  ensure
    poller&.stop
  end

  # While backed off, any tick that draws no rate-limit refusal restores the
  # cadence: whatever else went wrong, the budget stopped refusing.
  def test_a_non_rate_limit_failure_resets_an_active_backoff
    runner = FakeCommandRunner.new
    runner.stub "api get /my/boosts.json", exit_status: 7, stdout: error_envelope("api_error", "rate limited"), times: 3
    stub_transient_failure runner, "api get /my/boosts.json", stdout: "", exit_status: 6
    delays = Queue.new
    ticks = Queue.new
    poller = poller(runner, wait: ->(seconds) { delays << seconds; ticks.pop })

    poller.start
    waited = [ delays.pop ]
    2.times do
      ticks << true
      waited << delays.pop
    end

    assert_equal [ 15, 30, 15 ], waited
    assert_match(/no longer rate limited; resuming 15s boost polls/, @logs.string)
  ensure
    poller&.stop
  end

  # A configured interval at or above the cap is already slower than any
  # backoff could make it — rate limiting must not speed the poller up.
  def test_an_interval_beyond_the_cap_never_backs_off
    runner = FakeCommandRunner.new
    runner.stub "api get /my/boosts.json", exit_status: 7, stdout: error_envelope("api_error", "rate limit exceeded")
    delays = Queue.new
    ticks = Queue.new
    poller = poller(runner, interval: 600, wait: ->(seconds) { delays << seconds; ticks.pop })

    poller.start
    waited = [ delays.pop ]
    2.times do
      ticks << true
      waited << delays.pop
    end

    assert_equal [ 600, 600, 600 ], waited
    refute_match(/backing off/, @logs.string)
  ensure
    poller&.stop
  end

  # A rate-limited corroborating re-fetch is the same budget refusing: the
  # boost is forgotten for the next tick (as with any transient failure) and
  # the tick still backs off.
  def test_a_rate_limited_corroboration_backs_off_and_retries_the_boost
    runner = FakeCommandRunner.new
    runner.stub "api get /my/boosts.json", stdout: envelope([ received_boost ]), once: true
    runner.stub "api get /my/boosts.json", exit_status: 7, stdout: error_envelope("api_error", "rate limit exceeded"), times: 3
    runner.stub "api get /my/boosts.json", stdout: envelope([ received_boost ])
    poller = poller(runner)

    poller.poll
    assert_empty @output.string
    assert_match(/could not corroborate boost 88001/, @logs.string)
    assert_match(/rate limited; backing off boost polls to 30s/, @logs.string)

    poller.poll
    assert_equal 1, @output.string.lines.length
    assert_match(/no longer rate limited; resuming 15s boost polls/, @logs.string)
  end

  def test_stops_processing_boosts_after_a_rate_limited_corroboration
    second = received_boost("id" => 88002)
    runner = FakeCommandRunner.new
    runner.stub "api get /my/boosts.json", stdout: envelope([ received_boost, second ]), once: true
    runner.stub "api get /my/boosts.json", exit_status: 7, stdout: error_envelope("api_error", "rate limit exceeded")

    poller(runner).poll

    # The feed fetch plus one refused corroboration (three client attempts);
    # the second boost's verification waits for the backed-off next tick.
    assert_equal 1 + BasecampAgentConnector::Basecamp::Client::ATTEMPTS, runner.commands_matching(%r{api get /my/boosts\.json}).length
  end

  private
    def poller(runner, clock: -> { BEFORE_THE_BOOST }, wait: ->(_seconds) { }, trust_authorizer: authorizer, interval: 15)
      BasecampAgentConnector::Basecamp::BoostPoller.new \
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
        verifier: BasecampAgentConnector::Basecamp::Verifier.new(basecamp_cli: build_cli(runner), agent: @agent),
        emitter: BasecampAgentConnector::Emitter.new(output: @output),
        logger: @logs
    end
end
