require "test_helper"

class DeliveryReconcilerTest < Minitest::Test
  # Fixed, with the fixtures' timestamps fixed against it, so the lookback
  # boundary is the same on every day this runs.
  NOW = Time.utc(2026, 6, 28, 12, 0, 5)

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

    assert_equal 1, @output.string.lines.length
    assert_equal 99001, JSON.parse(@output.string)["event_id"]
    assert_equal({ "mentioned" => true, "subscribed" => false }, JSON.parse(@output.string)["trigger"])
  end

  def test_names_the_recovered_delivery_on_stderr
    reconciler(corroborating_runner(webhook_delivery(code: 0))).reconcile

    assert_match(/delivery 70001 of event 99001 \(comment_created\) on project 1 never reached this connector/, @logs.string)
    assert_match(/no response: the connection failed/, @logs.string)
  end

  def test_reports_the_response_code_of_a_delivery_that_was_answered_badly
    reconciler(corroborating_runner(webhook_delivery(code: 503))).reconcile

    assert_equal 1, @output.string.lines.length
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

    assert_equal 1, @output.string.lines.length
    assert_equal 1, runner.commands_matching(/basecamp show/).length
  end

  def test_does_not_emit_an_event_the_live_delivery_already_settled
    runner = corroborating_runner(webhook_delivery(code: 0))
    pipeline = pipeline(runner)
    pipeline.process(sample_payload)

    reconciler(runner, pipeline: pipeline).reconcile

    assert_equal 1, @output.string.lines.length
  end

  # The other order: Basecamp retries the delivery after the reconciliation
  # pass recovered it, and the retry is suppressed as the duplicate it is.
  def test_does_not_emit_again_when_the_delivery_is_retried_after_reconciliation
    runner = corroborating_runner(webhook_delivery(code: 0))
    pipeline = pipeline(runner)

    reconciler(runner, pipeline: pipeline).reconcile
    pipeline.process(sample_payload)

    assert_equal 1, @output.string.lines.length
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

  def test_does_not_emit_a_failed_delivery_older_than_the_lookback
    runner = corroborating_runner(webhook_delivery(code: 0, created_at: "2026-06-28T10:30:00Z"))

    reconciler(runner).reconcile

    assert_empty @output.string
    assert_empty runner.commands_matching(/basecamp show/)
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

    assert_equal 1, @output.string.lines.length
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

    assert_equal [ 99001, 99002 ], @output.string.lines.map { |line| JSON.parse(line)["event_id"] }
  end

  private
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

    def pipeline(runner)
      BasecampAgentConnector::Basecamp::Pipeline.new \
        authorizer: authorizer,
        agent: @agent,
        verifier: BasecampAgentConnector::Basecamp::Verifier.new(basecamp_cli: build_cli(runner), agent: @agent),
        emitter: BasecampAgentConnector::Emitter.new(output: @output),
        logger: @logs
    end

    def reconciler(runner, webhooks: webhooks(runner), pipeline: pipeline(runner),
      lookback: BasecampAgentConnector::Basecamp::DeliveryReconciler::DEFAULT_LOOKBACK)
      BasecampAgentConnector::Basecamp::DeliveryReconciler.new \
        webhooks: webhooks,
        pipeline: pipeline,
        lookback: lookback,
        logger: @logs,
        clock: -> { NOW }
    end
end
