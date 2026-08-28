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

    bridge.handler.call(Struct.new(:body).new(JSON.generate(chat_line_payload))).join

    assert_empty output.string
    assert_match(/ignored chat-kind payload/, logs.string)
    assert_empty runner.commands_matching(/chat line /)
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

    bridge.handler.call(Struct.new(:body).new(JSON.generate(boost_payload))).join

    assert_empty output.string
    assert_match(/ignored boost-kind payload/, logs.string)
    assert_empty runner.commands
  end

  private
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
