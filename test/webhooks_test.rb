require "test_helper"

class WebhooksTest < Minitest::Test
  def test_registers_one_webhook_per_project
    runner = FakeCommandRunner.new
    runner.stub "webhooks create", stdout: envelope("id" => 555)

    registrations = webhooks(runner).register_all(projects: [ 1, 2 ], url: hook_url, types: "Comment")

    assert_equal [ 1, 2 ], registrations.map(&:project)
  end

  def test_continues_past_a_registration_failure
    runner = FakeCommandRunner.new
    runner.stub(/--project 1\b/, stdout: envelope("id" => 555))
    runner.stub(/--project 2\b/, exit_status: 1, stderr: "limit reached")
    logs = StringIO.new

    registrations = webhooks(runner, logs).register_all(projects: [ 1, 2 ], url: hook_url, types: "Comment")

    assert_equal [ 1 ], registrations.map(&:project)
    assert_match(/failed to register webhook for project 2/, logs.string)
  end

  def test_retries_a_transient_failure_then_succeeds
    runner = FakeCommandRunner.new
    runner.stub "webhooks create", exit_status: 1, stdout: '{"ok":false,"error":"400 Bad Request"}', once: true
    runner.stub "webhooks create", stdout: envelope("id" => 555)

    registrations = webhooks(runner).register_all(projects: [ 1 ], url: hook_url, types: "Comment")

    assert_equal [ 1 ], registrations.map(&:project)
    assert_equal 2, runner.commands_matching(/webhooks create/).length
  end

  def test_gives_up_after_exhausting_attempts
    runner = FakeCommandRunner.new
    runner.stub "webhooks create", exit_status: 1, stdout: '{"ok":false,"error":"400 Bad Request"}'
    logs = StringIO.new

    registrations = webhooks(runner, logs).register_all(projects: [ 1 ], url: hook_url, types: "Comment")

    assert_empty registrations
    assert_equal 3, runner.commands_matching(/webhooks create/).length
    assert_match(/after 3 attempts/, logs.string)
  end

  def test_deletes_every_registered_webhook
    runner = FakeCommandRunner.new
    runner.stub "webhooks create", stdout: envelope("id" => 555)
    runner.stub "webhooks delete", exit_status: 0
    webhooks = webhooks(runner)

    webhooks.register_all(projects: [ 1, 2 ], url: hook_url, types: "Comment")
    webhooks.delete_all

    assert_equal 2, runner.commands_matching(/webhooks delete/).length
  end

  def test_reports_a_failed_deletion_and_keeps_going
    runner = FakeCommandRunner.new
    runner.stub "webhooks create", stdout: envelope("id" => 555)
    runner.stub "webhooks delete", exit_status: 1, stderr: "gone"
    logs = StringIO.new
    webhooks = webhooks(runner, logs)

    webhooks.register_all(projects: [ 1 ], url: hook_url, types: "Comment")
    webhooks.delete_all

    assert_match(/failed to delete webhook 555/, logs.string)
  end

  private
    def webhooks(runner, logs = StringIO.new)
      BasecampAgentConnector::Webhooks.new(basecamp_cli: build_cli(runner), logger: logs, wait: ->(_seconds) { })
    end

    def hook_url
      "https://example.org/hook/secret"
    end
end
