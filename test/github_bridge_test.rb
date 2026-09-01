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

  def test_sweeping_reaps_hooks_on_the_repos_the_dead_run_watched
    runner = FakeCommandRunner.new
    runner.stub "-X DELETE", exit_status: 0
    runner.stub "repos/acme/z/hooks", stdout: JSON.generate([ [ { "id" => 999, "config" => { "url" => "https://host.ts.net/gh/dead" } } ] ])
    runner.stub "repos/acme/a/hooks", stdout: "[[]]"

    swept = nil
    capture_io { swept = bridge(runner, repos: [ "acme/a" ]).sweep_orphans([ dead_run(repos: [ "acme/z" ], paths: [ "/gh/dead" ]) ]) }

    assert_equal [ "acme/a", "acme/z" ], swept
    assert_equal [ [ "gh", "api", "-X", "DELETE", "repos/acme/z/hooks/999" ] ], runner.commands_matching(/DELETE/)
  end

  def test_a_repo_that_cannot_be_listed_is_not_swept
    runner = FakeCommandRunner.new
    runner.stub "repos/acme/z/hooks", exit_status: 1, stderr: "404 Not Found"
    runner.stub "repos/acme/a/hooks", stdout: "[[]]"

    swept = nil
    capture_io { swept = bridge(runner, repos: [ "acme/a" ]).sweep_orphans([ dead_run(repos: [ "acme/z" ], paths: [ "/gh/dead" ]) ]) }

    assert_equal [ "acme/a" ], swept
  end

  def test_register_logs_whose_approvals_are_trusted
    runner = FakeCommandRunner.new
    runner.stub "/hooks", stdout: '{"id":888}'
    logs = StringIO.new

    bridge(runner, logger: logs).register(base_url: "https://host.ts.net")

    assert_match(/^Trust: approvals from @octocat only; changes_requested and commented reviews from any reviewer$/, logs.string)
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
    def bridge(runner, repos: [ "acme/a" ], logger: StringIO.new)
      BasecampAgentConnector::GitHub::Bridge.new \
        repos: repos,
        events: [ "pull_request_review" ],
        operator: "octocat",
        github_cli: build_github_cli(runner),
        emitter: BasecampAgentConnector::Emitter.new(output: StringIO.new),
        logger: logger
    end
end
