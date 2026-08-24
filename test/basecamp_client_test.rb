require "test_helper"

class BasecampClientTest < Minitest::Test
  # Measured 2026-08-21: the CLI reads credentials under a global mutual
  # exclusion, so exactly one of N simultaneous calls comes back authenticated.
  # The loser is not logged out and must not be reported as an error.
  LOCKED_OUT = "Not authenticated for profile:on-call-bot: credentials not found for profile:on-call-bot".freeze

  def test_a_call_that_lost_the_credential_race_is_retried
    runner = FakeCommandRunner.new
    runner.stub "basecamp me", stderr: LOCKED_OUT, exit_status: 1, once: true
    runner.stub "basecamp me", stdout: envelope("id" => 123)

    assert_equal 123, build_cli(runner).me.fetch("id")
    assert_equal 2, runner.commands_matching(/me/).length
  end

  def test_a_failure_that_is_not_the_credential_race_is_reported_at_once
    runner = FakeCommandRunner.new
    runner.stub "basecamp me", stderr: "not found", exit_status: 1

    assert_raises(BasecampAgentConnector::Basecamp::Client::Error) { build_cli(runner).me }
    assert_equal 1, runner.commands_matching(/me/).length, "a 404 must not be retried"
  end

  def test_a_call_that_never_wins_the_race_still_raises
    runner = FakeCommandRunner.new
    runner.stub "basecamp me", stderr: LOCKED_OUT, exit_status: 1

    error = assert_raises(BasecampAgentConnector::Basecamp::Client::Error) { build_cli(runner).me }

    assert_includes error.message, "credentials not found"
    assert_equal BasecampAgentConnector::Basecamp::Client::RETRY_DELAYS.length + 1,
      runner.commands_matching(/me/).length
  end

  # A permanent absence is the one failure a caller may stop asking about. Told
  # apart by the code in the CLI's envelope, so a timeout carrying the same HTTP
  # shape stays retryable.
  def test_a_deleted_recording_is_reported_as_gone
    runner = FakeCommandRunner.new
    runner.stub "basecamp show", stdout: '{"ok": false, "error": "Resource not found: x", "code": "not_found"}', exit_status: 1

    error = assert_raises(BasecampAgentConnector::Basecamp::Client::Error) { build_cli(runner).show("x") }

    assert error.gone?
  end

  def test_a_timeout_is_not_reported_as_gone
    runner = FakeCommandRunner.new
    runner.stub "basecamp show", stdout: '{"ok": false, "error": "context deadline exceeded", "code": "api_error"}', exit_status: 1

    error = assert_raises(BasecampAgentConnector::Basecamp::Client::Error) { build_cli(runner).show("x") }

    refute error.gone?
  end

  # The CLI omits "data" entirely on an empty listing, so unwrap returns the
  # envelope. Verbatim from `basecamp cards list --project 43795599 --column
  # 9956253701 -j`, 2026-08-22.
  EMPTY_LISTING = '{"ok": true, "summary": "0 cards"}'.freeze

  def test_an_empty_column_listing_is_no_cards_rather_than_the_envelope
    runner = FakeCommandRunner.new
    runner.stub "cards list", stdout: EMPTY_LISTING

    assert_equal [], build_cli(runner).cards_in_column(project: 1, column: 2)
  end

  def test_an_empty_assignment_listing_is_no_cards
    runner = FakeCommandRunner.new
    runner.stub "cards list", stdout: EMPTY_LISTING

    assert_equal [], build_cli(runner).cards_assigned_to("Clawdito")
  end

  def test_an_empty_event_listing_is_no_events
    runner = FakeCommandRunner.new
    runner.stub "events", stdout: '{"ok": true, "summary": "0 events"}'

    assert_equal [], build_cli(runner).events(789)
  end

  def test_me_returns_unwrapped_data
    runner = FakeCommandRunner.new
    runner.stub "basecamp me", stdout: envelope("id" => 123, "email_address" => "clawdito@example.com")

    assert_equal 123, build_cli(runner).me.fetch("id")
  end

  def test_me_passes_profile_flag
    runner = FakeCommandRunner.new
    runner.stub "basecamp me", stdout: envelope("id" => 200)

    build_cli(runner).me(profile: "clawdito")

    assert_includes runner.commands.last.join(" "), "--profile clawdito"
  end

  def test_create_webhook_passes_project_and_types
    runner = FakeCommandRunner.new
    runner.stub "webhooks create", stdout: envelope("id" => 555)

    webhook = build_cli(runner).create_webhook(url: "https://example.org/hook/x", project: 222, types: "Comment")

    assert_equal 555, webhook.fetch("id")
    command = runner.commands.first.join(" ")
    assert_includes command, "--project 222"
    assert_includes command, "--types Comment"
  end

  def test_delete_webhook_returns_success_flag
    runner = FakeCommandRunner.new
    runner.stub "webhooks delete", exit_status: 0

    assert build_cli(runner).delete_webhook(id: 555, project: 222)
  end

  def test_raises_on_command_failure
    runner = FakeCommandRunner.new
    runner.stub "basecamp me", exit_status: 1, stderr: "boom"

    assert_raises BasecampAgentConnector::Basecamp::Client::Error do
      build_cli(runner).me
    end
  end
end
