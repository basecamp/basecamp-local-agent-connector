require "test_helper"

class GithubBridgeTest < Minitest::Test
  def test_path_is_a_secret_gh_path
    assert_match(%r{\A/gh/[0-9a-f]{32}\z}, bridge(FakeCommandRunner.new).path)
  end

  def test_register_creates_a_webhook_at_the_funnel_url_for_each_repo
    runner = FakeCommandRunner.new
    runner.stub "/hooks", stdout: '{"id":888}'
    bridge = bridge(runner, repos: [ "acme/a", "acme/b" ])

    bridge.register(base_url: "https://host.ts.net")

    created = runner.commands_matching(%r{/hooks -X POST})
    assert_equal 2, created.length
    assert_includes created.first.join(" "), "config[url]=https://host.ts.net#{bridge.path}"
    assert_includes created.first.join(" "), "events[]=pull_request_review"
  end

  def test_teardown_deletes_registered_webhooks
    runner = FakeCommandRunner.new
    runner.stub "/hooks -X POST", stdout: '{"id":888}'
    runner.stub "-X DELETE", exit_status: 0
    bridge = bridge(runner)

    bridge.register(base_url: "https://host.ts.net")
    bridge.teardown

    assert_equal 1, runner.commands_matching(/-X DELETE/).length
  end

  private
    def bridge(runner, repos: [ "acme/a" ])
      BasecampAgentConnector::GitHub::Bridge.new \
        repos: repos,
        events: [ "pull_request_review" ],
        github_cli: build_github_cli(runner),
        emitter: BasecampAgentConnector::Emitter.new(output: StringIO.new),
        logger: StringIO.new
    end
end
