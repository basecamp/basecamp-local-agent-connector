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

  def test_deletes_only_the_webhooks_whose_path_a_dead_run_recorded
    runner = FakeCommandRunner.new
    runner.stub "webhooks list", stdout: envelope([
      { "id" => 111, "payload_url" => "https://host.ts.net/bc5/dead" },
      { "id" => 222, "payload_url" => "https://host.ts.net/bc5/alive" },
      { "id" => 333, "payload_url" => "https://host.ts.net/hook/someone-elses-build" } ])
    runner.stub "webhooks delete", stdout: envelope({})

    webhooks(runner).delete_orphans(projects: [ 7 ], paths: [ "/bc5/dead" ])

    deletions = runner.commands_matching(/webhooks delete/)
    assert_equal 1, deletions.length
    assert_includes deletions.first, "111"
  end

  def test_sweeps_nothing_when_no_dead_run_left_a_path
    runner = FakeCommandRunner.new

    webhooks(runner).delete_orphans(projects: [ 7 ], paths: [])

    assert_empty runner.commands
  end

  def test_a_listing_failure_leaves_the_project_alone
    runner = FakeCommandRunner.new
    runner.stub "webhooks list", exit_status: 1, stderr: "nope"
    logs = StringIO.new

    webhooks(runner, logs).delete_orphans(projects: [ 7 ], paths: [ "/bc5/dead" ])

    assert_empty runner.commands_matching(/webhooks delete/)
    assert_match(/could not list webhooks for project 7/, logs.string)
  end

  def test_restore_reactivates_a_webhook_basecamp_deactivated
    runner = FakeCommandRunner.new
    runner.stub "webhooks create", stdout: envelope("id" => 555)
    runner.stub "webhooks show 555", stdout: envelope("id" => 555, "active" => false)
    runner.stub "webhooks update 555", stdout: envelope("id" => 555, "active" => true)
    logs = StringIO.new
    webhooks = webhooks(runner, logs)
    webhooks.register_all(projects: [ 1 ], url: hook_url, types: "Comment")

    restored = webhooks.restore(url: hook_url, types: "Comment")

    assert_equal [ 555 ], restored.map(&:id)
    assert_equal [ [ "basecamp", "webhooks", "update", "555", "--project", "1", "--active", "-j" ] ],
      runner.commands_matching(/webhooks update/)
    assert_match(/webhook 555 on project 1 was DEACTIVATED by Basecamp.*10 failed deliveries.*Reactivated it in place/, logs.string)
  end

  def test_restore_leaves_an_active_webhook_alone
    runner = FakeCommandRunner.new
    runner.stub "webhooks create", stdout: envelope("id" => 555)
    runner.stub "webhooks show 555", stdout: envelope("id" => 555, "active" => true)
    logs = StringIO.new
    webhooks = webhooks(runner, logs)
    webhooks.register_all(projects: [ 1 ], url: hook_url, types: "Comment")

    restored = webhooks.restore(url: hook_url, types: "Comment")

    assert_empty restored
    assert_empty runner.commands_matching(/webhooks update/)
    assert_equal 1, runner.commands_matching(/webhooks create/).length
    assert_empty logs.string
  end

  # Someone cleaned up by hand (the README's manual-cleanup recipe on the
  # wrong id, say): Basecamp has nothing to reactivate, so a fresh
  # registration replaces it, and teardown deletes the replacement.
  def test_restore_re_registers_a_webhook_deleted_out_from_under_it
    runner = FakeCommandRunner.new
    runner.stub "webhooks create", stdout: envelope("id" => 555), once: true
    runner.stub "webhooks create", stdout: envelope("id" => 556)
    runner.stub "webhooks show 555", stdout: error_envelope("not_found", "Resource not found: webhook 555"), exit_status: 2
    runner.stub "webhooks delete", exit_status: 0
    logs = StringIO.new
    webhooks = webhooks(runner, logs)
    webhooks.register_all(projects: [ 1 ], url: hook_url, types: "Comment")

    restored = webhooks.restore(url: hook_url, types: "Comment")
    webhooks.delete_all

    assert_equal [ 556 ], restored.map(&:id)
    assert_match(/webhook 555 on project 1 is gone \(deleted outside this connector\); re-registered it as 556/, logs.string)
    deletions = runner.commands_matching(/webhooks delete/)
    assert_equal 1, deletions.length
    assert_includes deletions.first, "556"
  end

  def test_restore_keeps_a_registration_it_could_not_reactivate_and_says_so
    runner = FakeCommandRunner.new
    runner.stub "webhooks create", stdout: envelope("id" => 555)
    runner.stub "webhooks show 555", stdout: envelope("id" => 555, "active" => false)
    runner.stub "webhooks update 555", stdout: error_envelope("api_error", "The webhook limit for this project has been reached"), exit_status: 1
    runner.stub "webhooks delete", exit_status: 0
    logs = StringIO.new
    webhooks = webhooks(runner, logs)
    webhooks.register_all(projects: [ 1 ], url: hook_url, types: "Comment")

    restored = webhooks.restore(url: hook_url, types: "Comment")
    webhooks.delete_all

    assert_empty restored
    assert_match(/was DEACTIVATED by Basecamp.*Failed to reactivate it: .*webhook limit.*; retrying on the next check/, logs.string)
    assert_includes runner.commands_matching(/webhooks delete/).first, "555"
  end

  def test_restore_continues_past_a_webhook_it_could_not_check
    runner = FakeCommandRunner.new
    runner.stub(/webhooks create .*--project 1\b/, stdout: envelope("id" => 555))
    runner.stub(/webhooks create .*--project 2\b/, stdout: envelope("id" => 556))
    stub_transient_failure runner, "webhooks show 555"
    runner.stub "webhooks show 556", stdout: envelope("id" => 556, "active" => false)
    runner.stub "webhooks update 556", stdout: envelope("id" => 556, "active" => true)
    logs = StringIO.new
    webhooks = webhooks(runner, logs)
    webhooks.register_all(projects: [ 1, 2 ], url: hook_url, types: "Comment")

    restored = webhooks.restore(url: hook_url, types: "Comment")

    assert_equal [ 556 ], restored.map(&:id)
    assert_match(/could not check webhook 555 on project 1/, logs.string)
  end

  private
    def webhooks(runner, logs = StringIO.new)
      BasecampAgentConnector::Basecamp::Webhooks.new(basecamp_cli: build_cli(runner), logger: logs, wait: ->(_seconds) { })
    end

    def hook_url
      "https://example.org/hook/secret"
    end
end
