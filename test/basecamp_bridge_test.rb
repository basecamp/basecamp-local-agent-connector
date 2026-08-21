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

  private
    def bridge(runner, projects: [ "A" ])
      BasecampAgentConnector::Basecamp::Bridge.new \
        operator: operator_identity,
        agent: agent_identity,
        projects: projects,
        types: "Comment",
        basecamp_cli: build_cli(runner),
        emitter: BasecampAgentConnector::Emitter.new(output: StringIO.new),
        logger: StringIO.new
    end
end
