require "test_helper"

class GithubWebhooksTest < Minitest::Test
  def test_registers_one_webhook_per_repo
    runner = FakeCommandRunner.new
    runner.stub "/hooks", stdout: '{"id":888}'

    registrations = webhooks(runner).register_all(repos: [ "acme/a", "acme/b" ], url: hook_url, secret: "s3cret", events: events)

    assert_equal [ "acme/a", "acme/b" ], registrations.map(&:repo)
  end

  def test_continues_past_a_registration_failure
    runner = FakeCommandRunner.new
    runner.stub(%r{repos/acme/a/hooks}, stdout: '{"id":888}')
    runner.stub(%r{repos/acme/b/hooks}, exit_status: 1, stderr: "404 Not Found")
    logs = StringIO.new

    registrations = webhooks(runner, logs).register_all(repos: [ "acme/a", "acme/b" ], url: hook_url, secret: "s3cret", events: events)

    assert_equal [ "acme/a" ], registrations.map(&:repo)
    assert_match(/failed to register webhook for repo acme\/b/, logs.string)
  end

  def test_retries_a_transient_failure_then_succeeds
    runner = FakeCommandRunner.new
    runner.stub "/hooks", exit_status: 1, stderr: "502 Bad Gateway", once: true
    runner.stub "/hooks", stdout: '{"id":888}'

    registrations = webhooks(runner).register_all(repos: [ "acme/a" ], url: hook_url, secret: "s3cret", events: events)

    assert_equal [ "acme/a" ], registrations.map(&:repo)
    assert_equal 2, runner.commands_matching(%r{repos/acme/a/hooks -X POST}).length
  end

  def test_gives_up_after_exhausting_attempts
    runner = FakeCommandRunner.new
    runner.stub "/hooks", exit_status: 1, stderr: "502 Bad Gateway"
    logs = StringIO.new

    registrations = webhooks(runner, logs).register_all(repos: [ "acme/a" ], url: hook_url, secret: "s3cret", events: events)

    assert_empty registrations
    assert_match(/after 3 attempts/, logs.string)
  end

  def test_deletes_every_registered_webhook
    runner = FakeCommandRunner.new
    runner.stub "/hooks -X POST", stdout: '{"id":888}'
    runner.stub "-X DELETE", exit_status: 0
    webhooks = webhooks(runner)

    webhooks.register_all(repos: [ "acme/a", "acme/b" ], url: hook_url, secret: "s3cret", events: events)
    webhooks.delete_all

    assert_equal 2, runner.commands_matching(/-X DELETE/).length
  end

  def test_reports_a_failed_deletion_and_keeps_going
    runner = FakeCommandRunner.new
    runner.stub "/hooks -X POST", stdout: '{"id":888}'
    runner.stub "-X DELETE", exit_status: 1, stderr: "gone"
    logs = StringIO.new
    webhooks = webhooks(runner, logs)

    webhooks.register_all(repos: [ "acme/a" ], url: hook_url, secret: "s3cret", events: events)
    webhooks.delete_all

    assert_match(/failed to delete webhook 888 for repo acme\/a/, logs.string)
  end

  private
    def webhooks(runner, logs = StringIO.new)
      BasecampAgentConnector::GithubWebhooks.new(github_cli: build_github_cli(runner), logger: logs, wait: ->(_seconds) { })
    end

    def hook_url
      "https://example.ts.net/gh/secret"
    end

    def events
      [ "pull_request_review" ]
    end
end
