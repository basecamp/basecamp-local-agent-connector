require "test_helper"

class BasecampBridgeTest < Minitest::Test
  def test_path_is_a_secret_hook_path
    assert_match(%r{\A/bc5/[0-9a-f]{32}\z}, bridge(FakeCommandRunner.new).path)
  end

  def test_register_creates_a_webhook_at_the_funnel_url_for_each_project
    runner = FakeCommandRunner.new
    runner.stub "webhooks create", stdout: envelope("id" => 555)
    bridge = bridge(runner, projects: [ "A", "B" ])

    bridge.register(base_url: "https://host.ts.net")

    created = runner.commands_matching(/webhooks create/)
    assert_equal 2, created.length
    assert_includes created.first.join(" "), "https://host.ts.net#{bridge.path}"
  end

  def test_teardown_deletes_registered_webhooks
    runner = FakeCommandRunner.new
    runner.stub "webhooks create", stdout: envelope("id" => 555)
    runner.stub "webhooks delete", exit_status: 0
    bridge = bridge(runner)

    bridge.register(base_url: "https://host.ts.net")
    bridge.teardown

    assert_equal 1, runner.commands_matching(/webhooks delete/).length
  end

  def test_register_logs_the_active_trust_mode
    runner = FakeCommandRunner.new
    runner.stub "webhooks create", stdout: envelope("id" => 555)
    logs = StringIO.new

    bridge(runner, logger: logs).register(base_url: "https://host.ts.net")

    assert_match(/Trust: operator only \(operator@example\.com\); assignments: operator only/, logs.string)
  end

  def test_register_splits_chat_types_off_to_the_poller
    runner = FakeCommandRunner.new
    runner.stub "webhooks create", stdout: envelope("id" => 555)
    runner.stub "webhooks delete", exit_status: 0
    runner.stub "chat list", stdout: envelope([ chat_hash ])
    runner.stub "chat messages", stdout: envelope([ chat_line ])
    logs = StringIO.new
    bridge = bridge(runner, types: "Comment,Chat::Line", logger: logs)

    bridge.register(base_url: "https://host.ts.net")

    created = runner.commands_matching(/webhooks create/).first.join(" ")
    assert_includes created, "--types Comment"
    refute_includes created, "Chat"
    # Discovery is synchronous (the log needs the room count); fetching waits
    # for the poll thread so nothing emits before the readiness line prints.
    assert_equal 1, runner.commands_matching(/chat list/).length
    assert_empty runner.commands_matching(/chat messages/)
    assert_match(/Polling 1 Campfire\(s\)/, logs.string)
  ensure
    bridge.teardown
  end

  def test_chat_only_types_register_no_webhooks
    runner = FakeCommandRunner.new
    runner.stub "chat list", stdout: envelope([ chat_hash ])
    runner.stub "chat messages", stdout: empty_envelope
    bridge = bridge(runner, types: "Chat::Line")

    bridge.register(base_url: "https://host.ts.net")

    assert_nil bridge.path
    assert_empty runner.commands_matching(/webhooks create/)
    assert_equal 1, runner.commands_matching(/chat list/).length
  ensure
    bridge.teardown
  end

  def test_handler_refuses_chat_kind_webhook_payloads
    runner = FakeCommandRunner.new
    runner.stub "chat line ", stdout: envelope(chat_line)
    output = StringIO.new
    logs = StringIO.new
    bridge = bridge(runner, types: "Comment", logger: logs, output: output)

    assert_nil bridge.handler.call(request(chat_line_payload))

    assert_empty output.string
    assert_match(/ignored chat-kind payload/, logs.string)
    assert_empty runner.commands_matching(/chat line /)
  end

  def test_handler_answers_200_once_an_event_is_settled
    runner = FakeCommandRunner.new
    runner.stub "basecamp show", stdout: envelope(sample_recording)
    output = StringIO.new
    bridge = bridge(runner, output: output)

    assert_nil bridge.handler.call(request(sample_payload))
    assert_equal 1, output.string.lines.length
  end

  # A recording Basecamp says is not there is a verdict — the event is
  # dropped and the delivery is acknowledged, so a forged or deleted event
  # is never redelivered.
  def test_handler_answers_200_for_an_uncorroborated_event
    runner = FakeCommandRunner.new
    runner.stub "basecamp show", exit_status: 2, stdout: error_envelope("not_found", "Resource not found")
    output = StringIO.new
    logs = StringIO.new
    bridge = bridge(runner, logger: logs, output: output)

    assert_nil bridge.handler.call(request(sample_payload))

    assert_empty output.string
    assert_match(/dropped event 99001: not corroborated/, logs.string)
    assert_equal 1, runner.commands_matching(/basecamp show/).length
  end

  # A fetch the CLI could not complete is no verdict: answer 503 so bc3's
  # delivery job redelivers (Webhook::DeliveryJob retries any non-2xx), and
  # say so in the log instead of calling the event uncorroborated.
  def test_handler_answers_503_when_the_recording_could_not_be_fetched
    runner = FakeCommandRunner.new
    stub_transient_failure runner, "basecamp show"
    output = StringIO.new
    logs = StringIO.new
    bridge = bridge(runner, logger: logs, output: output)

    assert_equal 503, bridge.handler.call(request(sample_payload))

    assert_empty output.string
    assert_match(/could not corroborate event 99001: `basecamp show .*` failed on all 3 attempts.*; answered 503 so Basecamp redelivers/, logs.string)
    assert_match(/deactivates the webhook after 10 failed deliveries.*basecamp auth status --profile clawdito.*restart/, logs.string)
    refute_match(/not corroborated/, logs.string)
  end

  # The subscriber lookup is the second call a comment's verification makes,
  # after the recording fetch succeeded; a 503 from there names that call,
  # not the fetch that worked.
  def test_handler_answers_503_naming_the_subscriber_lookup_that_could_not_be_answered
    recording = sample_recording("content" => "<p>just a normal comment, no mention</p>")
    runner = FakeCommandRunner.new
    runner.stub "basecamp show", stdout: envelope(recording)
    stub_transient_failure runner, "subscriptions show"
    output = StringIO.new
    logs = StringIO.new
    bridge = bridge(runner, logger: logs, output: output)

    assert_equal 503, bridge.handler.call(request(sample_payload("recording" => recording)))

    assert_empty output.string
    assert_match(/could not corroborate event 99001: `basecamp subscriptions show .*` failed on all 3 attempts/, logs.string)
    refute_match(/fetch recording/, logs.string)
  end

  # bc3 answering 5xx (a deploy, an incident) is the other way Basecamp could
  # not be asked; a 200 here would settle a real mention as uncorroborated
  # while a 503 brings it back seconds later.
  def test_handler_answers_503_when_basecamp_answered_5xx
    runner = FakeCommandRunner.new
    stub_transient_failure runner, "basecamp show", exit_status: 7,
      stdout: error_envelope("api_error", "request failed after 3 attempts: Gateway error (503)")
    output = StringIO.new
    logs = StringIO.new
    bridge = bridge(runner, logger: logs, output: output)

    assert_equal 503, bridge.handler.call(request(sample_payload))

    assert_empty output.string
    assert_match(/Gateway error \(503\).*; answered 503 so Basecamp redelivers/, logs.string)
  end

  def test_a_redelivery_after_a_503_is_verified_afresh_and_emitted_once
    runner = FakeCommandRunner.new
    stub_transient_failure runner, "basecamp show"
    runner.stub "basecamp show", stdout: envelope(sample_recording)
    output = StringIO.new
    bridge = bridge(runner, output: output)

    assert_equal 503, bridge.handler.call(request(sample_payload))
    assert_nil bridge.handler.call(request(sample_payload))
    assert_nil bridge.handler.call(request(sample_payload))

    assert_equal 1, output.string.lines.length
  end

  def test_register_starts_the_boost_poller_and_logs_after_the_webhook_readiness_line
    runner = FakeCommandRunner.new
    runner.stub "webhooks create", stdout: envelope("id" => 555)
    runner.stub "webhooks delete", exit_status: 0
    logs = StringIO.new
    bridge = bridge(runner, logger: logs, boost_poll_interval: 60)

    bridge.register(base_url: "https://host.ts.net")

    listening = logs.string.index("Listening for mentions")
    polling = logs.string.index("Polling @Clawdito's received-boosts feed every 60s")
    refute_nil polling
    assert_operator listening, :<, polling
    # The poller starts but fetches nothing until its first interval pass, so
    # no event can beat the readiness lines to the funnel.
    assert_empty runner.commands_matching(%r{api get /my/boosts\.json})
  ensure
    bridge.teardown
  end

  def test_a_nil_boost_poll_interval_disables_the_poller
    runner = FakeCommandRunner.new
    runner.stub "webhooks create", stdout: envelope("id" => 555)
    runner.stub "webhooks delete", exit_status: 0
    logs = StringIO.new
    bridge = bridge(runner, logger: logs, boost_poll_interval: nil)

    bridge.register(base_url: "https://host.ts.net")
    bridge.teardown

    refute_match(/received-boosts feed/, logs.string)
  end

  def test_handler_refuses_boost_kind_webhook_payloads
    runner = FakeCommandRunner.new
    output = StringIO.new
    logs = StringIO.new
    bridge = bridge(runner, logger: logs, output: output)

    assert_nil bridge.handler.call(request(boost_payload))

    assert_empty output.string
    assert_match(/ignored boost-kind payload/, logs.string)
    assert_empty runner.commands
  end

  private
    def request(payload)
      BasecampAgentConnector::Server::Request.new(body: JSON.generate(payload), headers: {})
    end

    def bridge(runner, projects: [ "A" ], types: "Comment", logger: StringIO.new, output: StringIO.new,
      boost_poll_interval: nil)
      BasecampAgentConnector::Basecamp::Bridge.new \
        authorizer: authorizer,
        agent: agent_identity,
        projects: projects,
        types: types,
        basecamp_cli: build_cli(runner),
        emitter: BasecampAgentConnector::Emitter.new(output: output),
        logger: logger,
        boost_poll_interval: boost_poll_interval
    end
end
