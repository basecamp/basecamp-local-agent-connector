require "test_helper"

class DeliveryReconcilerTest < Minitest::Test
  # Fixed, with the fixtures' timestamps fixed against it, so the lookback
  # boundary is the same on every day this runs.
  NOW = Time.utc(2026, 6, 28, 12, 0, 5)

  # A registration list and its histories, set directly, so a test can change
  # what the next pass reads — or make a read fail — between passes.
  class FakeWebhooks
    attr_reader :histories

    def initialize(histories)
      @histories = histories
    end

    def registrations
      @histories.keys
    end

    def delivery_history(registration)
      @histories[registration]
    end
  end

  # Blocks inside the first command matching `pattern` until released, to hold
  # a live verification in flight while a reconciliation pass runs.
  class PausingCommandRunner < FakeCommandRunner
    attr_reader :paused, :resume

    def initialize(pattern)
      super()
      @pattern = pattern
      @pending = true
      @paused = Queue.new
      @resume = Queue.new
    end

    def run(*command)
      if @pending && command.join(" ").match?(@pattern)
        @pending = false
        @paused << true
        @resume.pop
      end

      super
    end
  end

  # Blocks inside the first line matching `pattern` until released: a stderr
  # pipe nobody is draining.
  class PausingLogger
    attr_reader :paused, :resume, :lines

    def initialize(pattern)
      @pattern = pattern
      @pending = true
      @paused = Queue.new
      @resume = Queue.new
      @lines = []
    end

    def puts(message)
      if @pending && message.match?(@pattern)
        @pending = false
        @paused << true
        @resume.pop
      end

      @lines << message
    end
  end

  def setup
    @agent = agent_identity
    @output = StringIO.new
    @logs = StringIO.new
  end

  # The bug this covers: bc3 recorded `response: {"code": 0}` for the delivery
  # of a comment that @mentioned the agent — the connection never completed, so
  # the connector never saw the request and logged nothing about it. The webhook
  # stayed active, the re-check found nothing wrong, and the mention was lost.
  def test_reconciles_a_failed_delivery_of_a_mentioning_comment_into_one_event
    runner = corroborating_runner(webhook_delivery(code: 0))

    reconciler(runner).reconcile

    assert_equal [ 99001 ], emitted_event_ids
    assert_equal({ "mentioned" => true, "subscribed" => false, "pinged" => false }, JSON.parse(@output.string)["trigger"])
  end

  def test_names_the_recovered_delivery_on_stderr
    reconciler(corroborating_runner(webhook_delivery(code: 0))).reconcile

    assert_match(/delivery 70001 of event 99001 \(comment_created\) on project 1 never reached this connector/, @logs.string)
    assert_match(/no response: the connection failed/, @logs.string)
  end

  def test_reports_the_response_code_of_a_delivery_that_was_answered_badly
    reconciler(corroborating_runner(webhook_delivery(code: 503))).reconcile

    assert_equal [ 99001 ], emitted_event_ids
    assert_match(/answered HTTP 503/, @logs.string)
  end

  def test_leaves_a_delivered_delivery_alone
    runner = corroborating_runner(webhook_delivery(code: 200))

    reconciler(runner).reconcile

    assert_empty @output.string
    assert_empty @logs.string
    assert_empty runner.commands_matching(/basecamp show/)
  end

  # Nothing is claimed twice because the replayed body is the one bc3 recorded,
  # so the reconciled event carries the same `event_id` a live delivery would
  # have — the key the pipeline's suppression already uses.
  def test_a_second_pass_neither_re_emits_nor_re_verifies
    runner = corroborating_runner(webhook_delivery(code: 0))
    reconciler = reconciler(runner)

    2.times { reconciler.reconcile }

    assert_equal [ 99001 ], emitted_event_ids
    assert_equal 1, runner.commands_matching(/basecamp show/).length
  end

  # A live delivery bc3 recorded as failed — verifying it overran bc3's 10s
  # timeout — did reach the connector. It is neither replayed nor announced as
  # a delivery that never arrived.
  def test_does_not_replay_an_event_the_live_delivery_already_settled
    runner = corroborating_runner(webhook_delivery(code: 0))
    pipeline = pipeline(runner)
    pipeline.process(sample_payload)

    reconciler(runner, pipeline: pipeline).reconcile

    assert_equal [ 99001 ], emitted_event_ids
    assert_equal 1, runner.commands_matching(/basecamp show/).length
    refute_match(/never reached this connector/, @logs.string)
  end

  # The other order: Basecamp retries the delivery after the reconciliation
  # pass recovered it, and the retry is suppressed as the duplicate it is.
  def test_does_not_emit_again_when_the_delivery_is_retried_after_reconciliation
    runner = corroborating_runner(webhook_delivery(code: 0))
    pipeline = pipeline(runner)

    reconciler(runner, pipeline: pipeline).reconcile
    pipeline.process(sample_payload)

    assert_equal [ 99001 ], emitted_event_ids
  end

  def test_refuses_a_failed_delivery_from_an_unauthorized_author
    body = sample_payload("creator" => { "id" => 300, "name" => "Someone", "email_address" => "someone@example.com" })
    runner = corroborating_runner(webhook_delivery(code: 0, body: body))

    reconciler(runner).reconcile

    assert_empty @output.string
    assert_empty runner.commands_matching(/basecamp show/)
  end

  def test_refuses_a_failed_delivery_the_agent_itself_authored
    body = sample_payload("creator" => { "id" => 200, "name" => "Clawdito", "email_address" => "clawdito@example.com" })
    runner = corroborating_runner(webhook_delivery(code: 0, body: body))

    reconciler(runner).reconcile

    assert_empty @output.string
    assert_empty runner.commands_matching(/basecamp show/)
  end

  def test_refuses_a_failed_delivery_the_re_fetched_recording_does_not_corroborate
    runner = registered_runner(webhook_delivery(code: 0))
    runner.stub "basecamp show", stdout: envelope(sample_recording("creator" => { "id" => 300, "email_address" => "someone@example.com" }))

    reconciler(runner).reconcile

    assert_empty @output.string
    assert_match(/dropped event 99001: not corroborated by Basecamp/, @logs.string)
  end

  def test_refuses_a_failed_delivery_whose_recording_is_still_a_draft
    runner = registered_runner(webhook_delivery(code: 0))
    runner.stub "basecamp show", stdout: envelope(sample_recording("status" => "drafted"))

    reconciler(runner).reconcile

    assert_empty @output.string
    assert_match(/dropped event 99001: not corroborated by Basecamp/, @logs.string)
  end

  # The live route refuses both kinds before verifying anything; a replay
  # reaches the same webhook pipeline, so it must meet the same refusal.
  def test_refuses_a_failed_delivery_of_a_kind_basecamp_never_delivers_by_webhook
    runner = corroborating_runner \
      webhook_delivery(code: 0, id: 70003, body: boost_payload),
      webhook_delivery(code: 0, id: 70004, body: chat_line_payload)

    reconciler(runner).reconcile

    assert_empty @output.string
    assert_empty runner.commands_matching(/basecamp show|chat line/)
    assert_match(/ignored boost-kind payload/, @logs.string)
    assert_match(/ignored chat-kind payload/, @logs.string)
  end

  # The live route answers 200 to a delivery Basecamp would not corroborate,
  # so bc3 never redelivers it; a reconciled one is settled the same way,
  # rather than re-verified every check and then reported as a hole.
  def test_settles_a_delivery_basecamp_would_not_corroborate_as_the_live_route_does
    now = NOW
    runner = registered_runner(webhook_delivery(code: 0))
    runner.stub "basecamp show", stdout: envelope(sample_recording("status" => "drafted"))
    reconciler = reconciler(runner, clock: -> { now })

    reconciler.reconcile
    now += 2 * 3600
    reconciler.reconcile

    assert_equal 1, runner.commands_matching(/basecamp show/).length
    refute_match(/MISSED/, @logs.string)
  end

  def test_does_not_emit_a_failed_delivery_older_than_the_lookback
    runner = corroborating_runner(webhook_delivery(code: 0, created_at: "2026-06-28T10:30:00Z"))

    reconciler(runner).reconcile

    assert_empty @output.string
    assert_empty runner.commands_matching(/basecamp show/)
  end

  def test_the_lookback_includes_its_own_boundary_and_nothing_older
    runner = corroborating_runner \
      webhook_delivery(code: 0, created_at: "2026-06-28T11:00:05Z"),
      webhook_delivery(code: 0, id: 70002, created_at: "2026-06-28T11:00:04Z", body: sample_payload("id" => 99002))

    reconciler(runner).reconcile

    assert_equal [ 99001 ], emitted_event_ids
    assert_match(/MISSED and NOT recovered: delivery 70002/, @logs.string)
  end

  def test_reports_a_delivery_older_than_the_lookback_as_an_unrecovered_hole
    runner = corroborating_runner(webhook_delivery(code: 0, created_at: "2026-06-28T10:30:00Z"))
    reconciler = reconciler(runner)

    2.times { reconciler.reconcile }

    assert_equal 1, @logs.string.scan(/MISSED and NOT recovered/).length
    assert_match(/delivery 70001 of event 99001 \(comment_created\) on project 1/, @logs.string)
    assert_match(/older than the 3600s reconciliation window/, @logs.string)
    assert_match(%r{https://3\.basecamp\.com/000/buckets/222/comments/456}, @logs.string)
  end

  # A failed delivery whose event did arrive by another delivery is no hole,
  # however old: telling the operator to hand it over would run it twice.
  def test_does_not_report_as_missed_an_event_heard_by_another_delivery
    runner = corroborating_runner(webhook_delivery(code: 0, created_at: "2026-06-28T10:30:00Z"))
    pipeline = pipeline(runner)
    pipeline.process(sample_payload)

    reconciler(runner, pipeline: pipeline).reconcile

    assert_equal [ 99001 ], emitted_event_ids
    refute_match(/MISSED/, @logs.string)
  end

  # Failing open here would lift the lookback bound off exactly the deliveries
  # the connector never received, where no suppression can stand in for it.
  def test_does_not_replay_a_delivery_whose_attempt_time_cannot_be_read
    runner = corroborating_runner(webhook_delivery(code: 0, created_at: "not a timestamp"))
    reconciler = reconciler(runner)

    2.times { reconciler.reconcile }

    assert_empty @output.string
    assert_empty runner.commands_matching(/basecamp show/)
    assert_equal 1, @logs.string.scan(/MISSED and NOT recovered: delivery 70001 .*attempt time could not be read/).length
  end

  def test_reconciles_a_body_recorded_as_a_json_string
    runner = corroborating_runner(webhook_delivery(code: 0, body: JSON.generate(sample_payload)))

    reconciler(runner).reconcile

    assert_equal [ 99001 ], emitted_event_ids
  end

  def test_reports_a_failed_delivery_whose_body_cannot_be_read_instead_of_settling_it_silently
    runner = corroborating_runner \
      webhook_delivery(code: 0, id: 70005, body: "{not json"),
      webhook_delivery(code: 0, id: 70006, body: nil),
      webhook_delivery(code: 0, id: 70007, body: sample_payload.except("id"))

    reconciler(runner).reconcile

    assert_empty @output.string
    [ 70005, 70006, 70007 ].each do |id|
      assert_match(/MISSED and NOT recovered: delivery #{id} of an unreadable event .*request body could not be read/, @logs.string)
    end
  end

  # The bug this covers: an entry in a shape nobody expected raised before it
  # was settled, so every pass died on it and never reached the mention behind.
  def test_a_malformed_delivery_does_not_stop_the_ones_behind_it
    malformed = { "id" => 70009, "created_at" => "2026-06-28T11:59:00Z", "request" => { "body" => [] }, "response" => [] }
    runner = corroborating_runner(malformed, webhook_delivery(code: 0))
    reconciler = reconciler(runner)

    2.times { reconciler.reconcile }

    assert_equal [ 99001 ], emitted_event_ids
    assert_equal 1, @logs.string.scan(/MISSED and NOT recovered: delivery 70009/).length
  end

  def test_skips_loudly_a_history_entry_that_carries_no_delivery_id
    runner = corroborating_runner([ "not", "a", "delivery" ], webhook_delivery(code: 0))

    reconciler(runner).reconcile

    assert_equal [ 99001 ], emitted_event_ids
    assert_match(/skipped an entry of the delivery history of webhook 555 on project 1: it carries no delivery id/, @logs.string)
  end

  def test_an_exception_reconciling_one_delivery_does_not_stop_the_ones_behind_it
    runner = corroborating_runner \
      webhook_delivery(code: 0, id: 70002, body: sample_payload("id" => 99002)),
      webhook_delivery(code: 0)
    real = pipeline(runner)
    exploding = Object.new
    exploding.define_singleton_method(:heard?) { |event_id| real.heard?(event_id) }
    exploding.define_singleton_method(:process) do |payload|
      raise "surprise" if payload["id"] == 99002

      real.process(payload)
    end

    reconciler(runner, pipeline: exploding).reconcile

    assert_equal [ 99001 ], emitted_event_ids
    assert_match(/could not reconcile delivery 70002 of webhook 555 on project 1: RuntimeError: surprise; not retried/, @logs.string)
  end

  # A corroboration the CLI could not complete is no verdict, so the delivery
  # stays unsettled and the next check is this pass's redelivery.
  def test_retries_a_delivery_whose_corroboration_could_not_be_completed
    runner = registered_runner(webhook_delivery(code: 0))
    stub_transient_failure(runner, "basecamp show")
    reconciler = reconciler(runner)

    reconciler.reconcile

    assert_empty @output.string
    assert_match(/could not corroborate reconciled event 99001/, @logs.string)

    runner.stub "basecamp show", stdout: envelope(sample_recording)
    reconciler.reconcile

    assert_equal [ 99001 ], emitted_event_ids
  end

  def test_reconciles_every_registration
    runner = FakeCommandRunner.new
    runner.stub(/webhooks create .*--project 1\b/, stdout: envelope("id" => 555))
    runner.stub(/webhooks create .*--project 2\b/, stdout: envelope("id" => 556))
    runner.stub "webhooks show 555", stdout: envelope("recent_deliveries" => [ webhook_delivery(code: 0) ])
    runner.stub "webhooks show 556", stdout: envelope("recent_deliveries" => [ webhook_delivery(code: 0, id: 70002,
      body: sample_payload("id" => 99002)) ])
    runner.stub "basecamp show", stdout: envelope(sample_recording)

    reconciler(runner, webhooks: webhooks(runner, projects: [ 1, 2 ])).reconcile

    assert_equal [ 99001, 99002 ], emitted_event_ids
  end

  # The WebhookMonitor's lock refuses a unit once a stop has begun; the pass
  # must end there, not run on through every delivery behind it.
  def test_a_pass_ends_at_the_first_unit_its_guard_refuses
    runner = corroborating_runner \
      webhook_delivery(code: 0),
      webhook_delivery(code: 0, id: 70002, body: sample_payload("id" => 99002))
    allowed = 2 # the history read, then the first delivery
    guard = lambda do |&unit|
      next false if allowed.zero?

      allowed -= 1
      unit.call
      true
    end

    reconciler(runner).reconcile(guard: guard)

    assert_equal [ 99001 ], emitted_event_ids
  end

  # The bug this covers: every delivery id ever read was kept for the session,
  # a busy project's whole traffic, though the history only ever holds 25.
  def test_keeps_settled_ids_only_for_the_deliveries_still_in_the_history
    registration = registration(555)
    webhooks = FakeWebhooks.new(registration => (1..25).map { |id| webhook_delivery(id: id) })
    reconciler = reconciler(FakeCommandRunner.new, webhooks: webhooks)

    reconciler.reconcile
    webhooks.histories[registration] = (26..50).map { |id| webhook_delivery(id: id) }
    reconciler.reconcile

    assert_equal (26..50).to_set, reconciler.instance_variable_get(:@settled_delivery_ids)[registration]
  end

  def test_a_history_that_could_not_be_read_lets_go_of_nothing
    registration = registration(555)
    old = webhook_delivery(code: 0, created_at: "2026-06-28T10:30:00Z")
    webhooks = FakeWebhooks.new(registration => [ old ])
    reconciler = reconciler(FakeCommandRunner.new, webhooks: webhooks)

    reconciler.reconcile
    webhooks.histories[registration] = nil
    reconciler.reconcile
    webhooks.histories[registration] = [ old ]
    reconciler.reconcile

    assert_equal 1, @logs.string.scan(/MISSED and NOT recovered/).length
  end

  def test_forgets_a_registration_no_longer_registered
    retired = registration(555)
    replacement = registration(556)
    webhooks = FakeWebhooks.new(retired => [ webhook_delivery ])
    reconciler = reconciler(FakeCommandRunner.new, webhooks: webhooks)

    reconciler.reconcile
    webhooks.histories.delete(retired)
    webhooks.histories[replacement] = []
    reconciler.reconcile

    assert_equal [ replacement ], reconciler.instance_variable_get(:@settled_delivery_ids).keys
  end

  # The bug this covers: an id still being verified counted as heard, so a
  # failed delivery of it was settled on the spot. When that live verification
  # then could not reach Basecamp, the pipeline forgot the id and answered 503
  # to a connection bc3 had already given up on — and nothing was left to
  # recover the trigger.
  def test_waits_out_a_live_verification_that_finds_no_verdict_and_then_recovers_the_delivery
    runner = PausingCommandRunner.new(/basecamp show/)
    runner.stub "webhooks show 555", stdout: envelope("id" => 555, "recent_deliveries" => [ webhook_delivery(code: 0) ])
    stub_transient_failure(runner, "basecamp show")
    runner.stub "basecamp show", stdout: envelope(sample_recording)
    pipeline = pipeline(runner)
    reconciler = reconciler(runner, pipeline: pipeline)

    live = Thread.new do
      pipeline.process(sample_payload)
    rescue BasecampAgentConnector::Basecamp::Client::TransientError
      :no_verdict
    end
    runner.paused.pop
    reconciling = Thread.new { reconciler.reconcile }
    sleep 0.05
    assert_predicate reconciling, :alive?

    runner.resume << true

    assert_equal :no_verdict, live.value
    reconciling.join(2)
    refute_predicate reconciling, :alive?
    assert_equal [ 99001 ], emitted_event_ids
  end

  # Too old to replay is still no hole while a live delivery of the same event
  # is being verified: the report waits for that verdict, and the delivery
  # that emits is the answer, not a miss announced a moment before it.
  def test_does_not_report_as_missed_an_event_whose_live_delivery_is_still_being_verified
    runner = PausingCommandRunner.new(/basecamp show/)
    runner.stub "webhooks show 555", stdout: envelope("id" => 555,
      "recent_deliveries" => [ webhook_delivery(code: 0, created_at: "2026-06-28T10:30:00Z") ])
    runner.stub "basecamp show", stdout: envelope(sample_recording)
    pipeline = pipeline(runner)
    reconciler = reconciler(runner, pipeline: pipeline)

    live = Thread.new { pipeline.process(sample_payload) }
    runner.paused.pop
    reconciling = Thread.new { reconciler.reconcile }
    sleep 0.05
    assert_predicate reconciling, :alive?

    runner.resume << true

    live.join(2)
    reconciling.join(2)
    refute_predicate reconciling, :alive?
    assert_equal [ 99001 ], emitted_event_ids
    refute_match(/MISSED/, @logs.string)
  end

  # And when that live verification finds no verdict, the old delivery really
  # was not recovered, so it is reported after all.
  def test_reports_an_old_delivery_whose_live_verification_found_no_verdict
    runner = PausingCommandRunner.new(/basecamp show/)
    runner.stub "webhooks show 555", stdout: envelope("id" => 555,
      "recent_deliveries" => [ webhook_delivery(code: 0, created_at: "2026-06-28T10:30:00Z") ])
    stub_transient_failure(runner, "basecamp show")
    pipeline = pipeline(runner)
    reconciler = reconciler(runner, pipeline: pipeline)

    live = Thread.new do
      pipeline.process(sample_payload)
    rescue BasecampAgentConnector::Basecamp::Client::TransientError
      :no_verdict
    end
    runner.paused.pop
    reconciling = Thread.new { reconciler.reconcile }
    sleep 0.05
    runner.resume << true

    assert_equal :no_verdict, live.value
    reconciling.join(2)
    assert_empty @output.string
    assert_equal 1, @logs.string.scan(/MISSED and NOT recovered: delivery 70001/).length
  end

  # The bug this covers: the MISSED line was written under the pipeline's
  # lock, so a stderr nobody was draining stalled every live delivery's claim
  # — unrelated events, on every project — until someone drained it.
  def test_a_blocked_missed_report_does_not_stall_an_unrelated_live_delivery
    runner = corroborating_runner(webhook_delivery(code: 0, created_at: "2026-06-28T10:30:00Z"))
    pipeline = pipeline(runner)
    logger = PausingLogger.new(/MISSED/)
    reconciler = reconciler(runner, pipeline: pipeline, logger: logger)
    reconciling = Thread.new { reconciler.reconcile }
    logger.paused.pop

    live = Thread.new { pipeline.process(sample_payload("id" => 99002)) }

    assert live.join(2), "the unrelated live delivery stalled behind the blocked report"
    assert_equal [ 99002 ], emitted_event_ids
  ensure
    logger&.resume&.push(true)
    reconciling&.join(2)
  end

  # What keeps the report atomic without the lock: a live delivery of the very
  # event being reported waits for the line, then claims the id afresh and
  # emits — after the MISSED line, never before it.
  def test_a_live_delivery_of_the_event_being_reported_waits_for_the_report_and_then_emits
    runner = corroborating_runner(webhook_delivery(code: 0, created_at: "2026-06-28T10:30:00Z"))
    pipeline = pipeline(runner)
    logger = PausingLogger.new(/MISSED/)
    reconciler = reconciler(runner, pipeline: pipeline, logger: logger)
    reconciling = Thread.new { reconciler.reconcile }
    logger.paused.pop

    live = Thread.new { pipeline.process(sample_payload) }
    refute live.join(0.1), "the live delivery emitted while its miss was still being reported"
    assert_empty @output.string

    logger.resume << true

    assert live.join(2)
    assert reconciling.join(2)
    assert_equal [ 99001 ], emitted_event_ids
    assert_equal 1, logger.lines.grep(/MISSED and NOT recovered: delivery 70001/).length
  end

  private
    def emitted_event_ids
      @output.string.lines.map { |line| JSON.parse(line)["event_id"] }
    end

    def registration(id, project: 1)
      BasecampAgentConnector::Basecamp::Webhooks::Registration.new(project: project, id: id)
    end

    def corroborating_runner(*deliveries)
      registered_runner(*deliveries).tap do |runner|
        runner.stub "basecamp show", stdout: envelope(sample_recording)
      end
    end

    def registered_runner(*deliveries)
      FakeCommandRunner.new.tap do |runner|
        runner.stub "webhooks show 555", stdout: envelope("id" => 555, "recent_deliveries" => deliveries)
      end
    end

    def webhooks(runner, projects: [ 1 ])
      runner.stub "webhooks create", stdout: envelope("id" => 555)

      BasecampAgentConnector::Basecamp::Webhooks.new(basecamp_cli: build_cli(runner), logger: @logs,
        wait: ->(_seconds) { }).tap do |webhooks|
        webhooks.register_all(projects: projects, url: "https://host.example.ts.net/bc5/abc", types: "Comment")
      end
    end

    # Built as the Bridge builds the webhook route's pipeline, which is the one
    # the reconciler shares.
    def pipeline(runner)
      BasecampAgentConnector::Basecamp::Pipeline.new \
        authorizer: authorizer,
        agent: @agent,
        verifier: BasecampAgentConnector::Basecamp::Verifier.new(basecamp_cli: build_cli(runner), agent: @agent),
        emitter: BasecampAgentConnector::Emitter.new(output: @output),
        webhook: true,
        logger: @logs
    end

    def reconciler(runner, webhooks: webhooks(runner), pipeline: pipeline(runner),
      lookback: BasecampAgentConnector::Basecamp::DeliveryReconciler::DEFAULT_LOOKBACK, clock: -> { NOW }, logger: @logs)
      BasecampAgentConnector::Basecamp::DeliveryReconciler.new \
        webhooks: webhooks,
        pipeline: pipeline,
        lookback: lookback,
        logger: logger,
        clock: clock
    end
end
