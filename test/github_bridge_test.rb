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

    assert_match(/^Trust: approvals from @octocat only; changes_requested from any reviewer; commented from any reviewer, except @octocat's own 🤖-marked replies$/, logs.string)
  end

  # End to end over the route: a signed delivery of a review the operator's
  # login submitted with every line 🤖-marked — the dispatched agent's own
  # reply — is answered and dropped, never emitted.
  def test_handler_drops_the_operators_agent_marked_comment_review
    review = review_hash("state" => "commented", "body" => "🤖 addressed in 3f2a1c9")
    runner = FakeCommandRunner.new
    runner.stub "/hooks", stdout: '{"id":888}'
    runner.stub(%r{reviews/7001$}, stdout: JSON.generate(review.merge("state" => "COMMENTED")))
    runner.stub "reviews/7001/comments", stdout: "[]"
    output = StringIO.new
    logs = StringIO.new
    bridge = bridge(runner, logger: logs, emitter: BasecampAgentConnector::Emitter.new(output: output))
    bridge.register(base_url: "https://host.ts.net")

    deliver bridge, review_payload("review" => review), secret: logged_hmac_secret(logs)

    assert_match(/dropped review 7001: commented by the operator \(octocat\) with every line 🤖-marked/, wait_for_log(logs, /dropped review/))
    assert_empty output.string
  end

  # Same route, same login: an unmarked word makes it a person's review, and
  # it reaches STDOUT.
  def test_handler_emits_the_operators_hand_written_comment_review
    review = review_hash("state" => "commented", "body" => "this naming still reads backwards")
    runner = FakeCommandRunner.new
    runner.stub "/hooks", stdout: '{"id":888}'
    runner.stub(%r{reviews/7001$}, stdout: JSON.generate(review.merge("state" => "COMMENTED")))
    runner.stub "reviews/7001/comments", stdout: "[]"
    output = StringIO.new
    logs = StringIO.new
    bridge = bridge(runner, logger: logs, emitter: BasecampAgentConnector::Emitter.new(output: output))
    bridge.register(base_url: "https://host.ts.net")

    deliver bridge, review_payload("review" => review), secret: logged_hmac_secret(logs)

    assert_equal 7001, JSON.parse(wait_for_log(output, /review_id/))["review_id"]
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
    # The bridge logs its own HMAC secret so a repo can be registered against a
    # running connector by hand; a delivery has to be signed with it.
    def logged_hmac_secret(logs)
      logs.string[/secret ([0-9a-f]{64})/, 1]
    end

    def deliver(bridge, payload, secret:)
      body = JSON.generate(payload)
      bridge.handler.call BasecampAgentConnector::Server::Request.new(body: body,
        headers: { "x-hub-signature-256" => [ sign(body, secret) ] })
    end

    # The handler answers at once and verifies on its own thread, so the
    # verdict lands a moment later.
    def wait_for_log(buffer, pattern)
      100.times do
        return buffer.string if buffer.string.match?(pattern)

        sleep 0.01
      end

      flunk "nothing matching #{pattern.inspect} was written: #{buffer.string.inspect}"
    end

    def bridge(runner, repos: [ "acme/a" ], logger: StringIO.new, emitter: BasecampAgentConnector::Emitter.new(output: StringIO.new))
      BasecampAgentConnector::GitHub::Bridge.new \
        repos: repos,
        events: [ "pull_request_review" ],
        operator: "octocat",
        github_cli: build_github_cli(runner),
        emitter: emitter,
        logger: logger
    end
end
