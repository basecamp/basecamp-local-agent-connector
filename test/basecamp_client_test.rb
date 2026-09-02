require "test_helper"

class BasecampClientTest < Minitest::Test
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

  # The CLI resolves BASECAMP_PROFILE ahead of its configured default, so a
  # command with no --profile runs as whatever the environment pins; the
  # client's default profile makes the operator explicit on each of them.
  def test_unflagged_commands_run_under_the_default_profile
    runner = FakeCommandRunner.new
    runner.stub "chat list", stdout: envelope([])
    runner.stub "webhooks delete", exit_status: 0

    cli = BasecampAgentConnector::Basecamp::Client.new(command_runner: runner, profile: "jorge", wait: ->(_seconds) { })
    cli.chats(project: 222)
    cli.delete_webhook(id: 555, project: 222)

    assert_equal 2, runner.commands.length
    runner.commands.each { |command| assert_includes command.join(" "), "--profile jorge" }
  end

  def test_an_explicit_profile_is_not_overridden_by_the_default
    runner = FakeCommandRunner.new
    runner.stub "basecamp me", stdout: envelope("id" => 200)

    BasecampAgentConnector::Basecamp::Client.new(command_runner: runner, profile: "jorge", wait: ->(_seconds) { }).me(profile: "clawdito")

    assert_equal 1, runner.commands.last.count("--profile")
    assert_includes runner.commands.last.join(" "), "--profile clawdito"
  end

  def test_malformed_json_from_a_successful_command_is_a_transient_error
    runner = FakeCommandRunner.new
    runner.stub "chat list", stdout: '{"data": [{"id": 333, "tit'

    error = assert_raises(BasecampAgentConnector::Basecamp::Client::TransientError) { build_cli(runner).chats(project: 222) }
    assert_match(/malformed JSON/, error.message)
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

  # A create is not re-asked: Basecamp may have registered the webhook and
  # lost only the answer, and a second create would register a second
  # webhook whose id is never kept for teardown. The registration's own
  # outer retry (Webhooks#create_with_retries) decides whether to try again.
  def test_create_webhook_is_not_retried_on_a_transient_failure
    runner = FakeCommandRunner.new
    stub_transient_failure runner, "webhooks create"
    delays = []

    error = assert_raises(BasecampAgentConnector::Basecamp::Client::TransientError) do
      build_cli(runner, wait: ->(seconds) { delays << seconds }).create_webhook(url: "https://example.org/hook/x", project: 222, types: "Comment")
    end

    assert_equal 1, runner.commands.length
    assert_empty delays
    assert_match(/`basecamp webhooks create .*` failed: .*auth_required/, error.message)
  end

  def test_delete_webhook_returns_success_flag
    runner = FakeCommandRunner.new
    runner.stub "webhooks delete", exit_status: 0

    assert build_cli(runner).delete_webhook(id: 555, project: 222)
  end

  def test_subscription_shows_the_subscribers_of_an_item
    runner = FakeCommandRunner.new
    runner.stub "subscriptions show", stdout: subscribers_envelope(200)

    subscription = build_cli(runner).subscription("https://example.org/buckets/1/recordings/789")

    assert_equal 200, subscription["subscribers"].first.fetch("id")
    assert_includes runner.commands.first.join(" "),
      "subscriptions show https://example.org/buckets/1/recordings/789"
  end

  def test_received_boosts_fetches_the_profiles_boost_feed
    runner = FakeCommandRunner.new
    runner.stub "api get /my/boosts.json", stdout: envelope([ received_boost ])

    boosts = build_cli(runner).received_boosts(profile: "clawdito")

    assert_equal 88001, boosts.first.fetch("id")
    assert_includes runner.commands.first.join(" "), "api get /my/boosts.json --profile clawdito"
  end

  def test_raises_on_command_failure
    runner = FakeCommandRunner.new
    runner.stub "basecamp me", exit_status: 1, stderr: "boom"

    assert_raises BasecampAgentConnector::Basecamp::Client::Error do
      build_cli(runner).me
    end
  end

  # The keyring-probe race: a concurrent CLI invocation lost its keyring
  # probe, fell back to a stale credentials file, and reported auth_required
  # though the profile is fine. The next attempt, once the neighbours are
  # done, succeeds — and the caller never learns there was a hiccup.
  def test_retries_a_transient_failure_and_returns_the_eventual_answer
    runner = FakeCommandRunner.new
    runner.stub "basecamp show", exit_status: 3, once: true,
      stdout: error_envelope("auth_required", "Not authenticated for profile:clawdito: credentials not found")
    runner.stub "basecamp show", stdout: envelope(sample_recording)
    delays = []

    recording = build_cli(runner, wait: ->(seconds) { delays << seconds }).show("https://example.org/recordings/456")

    assert_equal 456, recording.fetch("id")
    assert_equal 2, runner.commands_matching(/basecamp show/).length
    assert_equal [ BasecampAgentConnector::Basecamp::Client::RETRY_DELAYS.first ], delays
  end

  def test_a_token_refresh_failure_is_transient
    runner = FakeCommandRunner.new
    runner.stub "basecamp show", exit_status: 7, once: true,
      stdout: error_envelope("api_error", "token refresh failed: Post \"https://launchpad.localhost:3011/oauth/token\": connection refused")
    runner.stub "basecamp show", stdout: envelope(sample_recording)

    assert_equal 456, build_cli(runner).show("https://example.org/recordings/456").fetch("id")
  end

  # bc3 answering 5xx, or the CLI's own circuit breaker refusing to ask,
  # arrive as api_error too — each with a fixed message from the SDK or the
  # CLI, which is all an envelope without `retryable` (an older CLI) has to
  # key on. None is a verdict on the recording.
  def test_a_5xx_or_an_open_circuit_is_transient
    [
      "Gateway error (503)",
      "request failed after 3 attempts: Gateway error (502)",
      "Server error (500)",
      "request failed after 3 attempts: API error: 502 Bad Gateway",
      "Service temporarily unavailable"
    ].each do |message|
      runner = FakeCommandRunner.new
      stub_transient_failure runner, "basecamp show", stdout: error_envelope("api_error", message), exit_status: 7

      error = assert_raises(BasecampAgentConnector::Basecamp::Client::TransientError, message) do
        build_cli(runner).show("https://example.org/recordings/456")
      end

      assert_equal BasecampAgentConnector::Basecamp::Client::ATTEMPTS, runner.commands_matching(/basecamp show/).length, message
      assert_includes error.message, message
    end
  end

  # A CLI that classifies its own failures says so in the envelope, and a
  # positive word is taken on its own: a code and message the fallback list
  # has never heard of is retried when the CLI says it is retryable.
  def test_a_retryable_envelope_is_transient_whatever_its_code
    [
      error_envelope("timeout", "request timed out after 30s", retryable: true),
      error_envelope("api_error", "upstream reset the connection", retryable: true)
    ].each do |stdout|
      runner = FakeCommandRunner.new
      stub_transient_failure runner, "basecamp show", stdout: stdout, exit_status: 7

      error = assert_raises(BasecampAgentConnector::Basecamp::Client::TransientError, stdout) do
        build_cli(runner).show("https://example.org/recordings/456")
      end

      assert_equal BasecampAgentConnector::Basecamp::Client::ATTEMPTS, runner.commands_matching(/basecamp show/).length, stdout
      assert_match(/failed on all 3 attempts/, error.message)
    end
  end

  # `retryable: false` is where the CLI leaves the failures it never
  # classified, and those include the ones the retry loop exists for: the
  # keyring race's auth_required and token-refresh api_error (the CLI's
  # ErrAuth and ErrAPI constructors set no Retryable) and bc3's 500 (the
  # SDK classifies only 502–504). A false stamp on a listed code or message
  # must not narrow the list, or the first CLI release that emits the field
  # turns the race into a dropped event.
  def test_a_false_retryable_stamp_does_not_narrow_the_fallback_list
    [
      error_envelope("auth_required", "Not authenticated for profile:clawdito: credentials not found", retryable: false),
      error_envelope("api_error", "token refresh failed: Post \"https://launchpad.localhost:3011/oauth/token\": connection refused", retryable: false),
      error_envelope("api_error", "Server error (500)", retryable: false)
    ].each do |stdout|
      runner = FakeCommandRunner.new
      stub_transient_failure runner, "basecamp show", stdout: stdout, exit_status: 3
      delays = []

      error = assert_raises(BasecampAgentConnector::Basecamp::Client::TransientError, stdout) do
        build_cli(runner, wait: ->(seconds) { delays << seconds }).show("https://example.org/recordings/456")
      end

      assert_equal BasecampAgentConnector::Basecamp::Client::ATTEMPTS, runner.commands_matching(/basecamp show/).length, stdout
      assert_equal BasecampAgentConnector::Basecamp::Client::RETRY_DELAYS, delays, stdout
      assert_match(/failed on all 3 attempts/, error.message)
    end
  end

  # A false stamp on a code and message the list does not know stays a
  # verdict — the same reading an older CLI's envelope gets, so this holds
  # with or without the field.
  def test_a_false_retryable_stamp_on_an_unlisted_code_is_a_verdict
    [
      error_envelope("not_found", "Resource not found: https://example.org/recordings/456.json", retryable: false),
      error_envelope("api_error", "API error: 410 Gone", retryable: false)
    ].each do |stdout|
      runner = FakeCommandRunner.new
      runner.stub "basecamp show", exit_status: 2, stdout: stdout
      delays = []

      error = assert_raises(BasecampAgentConnector::Basecamp::Client::Error, stdout) do
        build_cli(runner, wait: ->(seconds) { delays << seconds }).show("https://example.org/recordings/456")
      end

      refute_kind_of BasecampAgentConnector::Basecamp::Client::TransientError, error, stdout
      assert_equal 1, runner.commands_matching(/basecamp show/).length, stdout
      assert_empty delays, stdout
    end
  end

  # A 4xx Basecamp reports as api_error is its verdict, like a not_found.
  def test_a_4xx_api_error_is_not_transient
    runner = FakeCommandRunner.new
    runner.stub "basecamp show", exit_status: 7, stdout: error_envelope("api_error", "API error: 410 Gone")

    error = assert_raises(BasecampAgentConnector::Basecamp::Client::Error) { build_cli(runner).show("https://example.org/recordings/456") }

    refute_kind_of BasecampAgentConnector::Basecamp::Client::TransientError, error
    assert_equal 1, runner.commands.length
  end

  def test_a_nonzero_exit_without_an_envelope_is_transient
    runner = FakeCommandRunner.new
    runner.stub "basecamp show", exit_status: 1, stderr: "502 Bad Gateway", once: true
    runner.stub "basecamp show", stdout: envelope(sample_recording)

    assert_equal 456, build_cli(runner).show("https://example.org/recordings/456").fetch("id")
  end

  def test_a_transient_failure_that_outlasts_the_retries_is_a_transient_error
    runner = FakeCommandRunner.new
    stub_transient_failure runner, "basecamp show"
    delays = []

    error = assert_raises(BasecampAgentConnector::Basecamp::Client::TransientError) do
      build_cli(runner, wait: ->(seconds) { delays << seconds }).show("https://example.org/recordings/456")
    end

    assert_equal BasecampAgentConnector::Basecamp::Client::ATTEMPTS, runner.commands_matching(/basecamp show/).length
    assert_equal BasecampAgentConnector::Basecamp::Client::RETRY_DELAYS, delays
    assert_match(/failed on all 3 attempts: .*auth_required/, error.message)
  end

  # Basecamp's own verdict is final: a recording that is not there (deleted,
  # or never existed because the POST was forged) must stay uncorroborated,
  # and asking twice more would only delay saying so.
  def test_does_not_retry_a_not_found
    runner = FakeCommandRunner.new
    runner.stub "basecamp show", exit_status: 2, stdout: error_envelope("not_found", "Resource not found: https://example.org/recordings/456.json")
    delays = []

    error = assert_raises(BasecampAgentConnector::Basecamp::Client::Error) do
      build_cli(runner, wait: ->(seconds) { delays << seconds }).show("https://example.org/recordings/456")
    end

    refute_kind_of BasecampAgentConnector::Basecamp::Client::TransientError, error
    assert_equal 1, runner.commands_matching(/basecamp show/).length
    assert_empty delays
  end

  def test_does_not_retry_a_forbidden
    runner = FakeCommandRunner.new
    runner.stub "basecamp show", exit_status: 4, stdout: error_envelope("forbidden", "Access denied")

    error = assert_raises(BasecampAgentConnector::Basecamp::Client::Error) { build_cli(runner).show("https://example.org/recordings/456") }

    refute_kind_of BasecampAgentConnector::Basecamp::Client::TransientError, error
    assert_equal 1, runner.commands.length
  end

  def test_retries_malformed_output_from_a_successful_command
    runner = FakeCommandRunner.new
    runner.stub "chat list", stdout: '{"data": [{"id": 333, "tit', once: true
    runner.stub "chat list", stdout: envelope([ chat_hash ])

    assert_equal 333, build_cli(runner).chats(project: 222).first.fetch("id")
  end

  # A failing command prints the {"ok": false, ...} error envelope on stdout
  # and exits nonzero (verified against production); the raised error carries
  # that envelope as its detail, which the pollers log. A 429 arrives as
  # `rate_limit` — the one spelling the SDK (checkResponse, the 429 arm of
  # the raw client) and the CLI (convertSDKError, for its own limiter and
  # bulkhead too) give it, exit status 5 — and is no verdict on the
  # recording, so it is retried and then surfaces transient.
  def test_a_rate_limit_is_transient_and_surfaces_the_envelope_as_detail
    runner = FakeCommandRunner.new
    stub_transient_failure runner, "chat messages", exit_status: 5,
      stdout: JSON.generate("ok" => false, "error" => "Rate limit exceeded", "code" => "rate_limit",
        "hint" => "Too many requests. Please wait before trying again.")

    error = assert_raises(BasecampAgentConnector::Basecamp::Client::TransientError) do
      build_cli(runner).chat_lines(project: 222, chat: 333, limit: 50)
    end

    assert_equal BasecampAgentConnector::Basecamp::Client::ATTEMPTS, runner.commands.length
    assert_match(/failed on all 3 attempts: .*rate_limit/, error.message)
    assert_predicate error, :rate_limited?
  end

  # Production evidence (project 48672814's 15s chat poll): today's binary
  # relays bc3's 429 body as a generic api_error — {"ok": false, "error":
  # "rate limit exceeded", "code": "api_error"} on stdout, nonzero exit —
  # rather than the taxonomy's dedicated rate_limit code. Either spelling is
  # "not now", not a verdict: retried through like any transient failure
  # (the budget window rolls over in seconds) and recognizable on the way
  # out, so a caller that can defer eases off instead of recording a drop.
  def test_a_rate_limited_api_error_is_transient_and_recognizable
    runner = FakeCommandRunner.new
    stub_transient_failure runner, "chat messages", exit_status: 7, stdout: error_envelope("api_error", "rate limit exceeded")

    error = assert_raises(BasecampAgentConnector::Basecamp::Client::TransientError) do
      build_cli(runner).chat_lines(project: 222, chat: 333, limit: 50)
    end

    assert_equal BasecampAgentConnector::Basecamp::Client::ATTEMPTS, runner.commands.length
    assert_predicate error, :rate_limited?
    assert_equal "api_error", error.code
  end

  # Under concurrent load the budget refusal and the keyring race co-occur:
  # an early attempt's rate-limit envelope must survive a final attempt that
  # fails the other transient way, or the caller would pace as if no refusal
  # happened.
  def test_rate_limit_evidence_survives_mixed_transient_retries
    runner = FakeCommandRunner.new
    runner.stub "chat messages", exit_status: 7, stdout: error_envelope("api_error", "rate limit exceeded"), once: true
    runner.stub "chat messages", exit_status: 3, stdout: error_envelope("auth_required", "Not authenticated"), times: 2

    error = assert_raises(BasecampAgentConnector::Basecamp::Client::TransientError) do
      build_cli(runner).chat_lines(project: 222, chat: 333, limit: 50)
    end

    assert_predicate error, :rate_limited?
  end

  # A verdict on a later attempt proves the budget answered — it stands as
  # itself, unflagged by the earlier refusal.
  def test_a_verdict_after_a_rate_limited_attempt_stands_unflagged
    runner = FakeCommandRunner.new
    runner.stub "basecamp show", exit_status: 7, stdout: error_envelope("api_error", "rate limit exceeded"), once: true
    runner.stub "basecamp show", exit_status: 2, stdout: error_envelope("not_found", "Resource not found: 456")

    error = assert_raises(BasecampAgentConnector::Basecamp::Client::Error) { build_cli(runner).show("456") }

    refute_kind_of BasecampAgentConnector::Basecamp::Client::TransientError, error
    refute_predicate error, :rate_limited?
    assert_equal "not_found", error.code
  end

  def test_a_non_rate_limit_failure_is_not_mistaken_for_one
    runner = FakeCommandRunner.new
    runner.stub "basecamp show", exit_status: 2, stdout: error_envelope("not_found", "Resource not found: 456")

    error = assert_raises(BasecampAgentConnector::Basecamp::Client::Error) { build_cli(runner).show("456") }

    refute_predicate error, :rate_limited?
    assert_equal "not_found", error.code
  end

  def test_a_failure_without_an_envelope_carries_no_code
    runner = FakeCommandRunner.new
    stub_transient_failure runner, "basecamp show", stdout: "", exit_status: 1

    error = assert_raises(BasecampAgentConnector::Basecamp::Client::TransientError) { build_cli(runner).show("456") }

    assert_nil error.code
    refute_predicate error, :rate_limited?
  end

  def test_chats_lists_a_projects_chats
    runner = FakeCommandRunner.new
    runner.stub "chat list", stdout: envelope([ chat_hash ])

    chats = build_cli(runner).chats(project: 222)

    assert_equal 333, chats.first.fetch("id")
    assert_includes runner.commands.first.join(" "), "chat list --project 222"
  end

  def test_chat_lines_fetches_recent_lines_for_a_room
    runner = FakeCommandRunner.new
    runner.stub "chat messages", stdout: envelope([ chat_line ])

    lines = build_cli(runner).chat_lines(project: 222, chat: 333, limit: 25)

    assert_equal 91001, lines.first.fetch("id")
    assert_includes runner.commands.first.join(" "), "chat messages --project 222 --room 333 --limit 25"
  end

  # `chat messages` on a room with no lines omits "data" from the envelope
  # entirely; the list commands must come back empty, not as the bare
  # envelope hash.
  def test_a_dataless_envelope_is_an_empty_list_for_list_commands
    runner = FakeCommandRunner.new
    runner.stub "chat messages", stdout: empty_envelope
    runner.stub "chat list", stdout: empty_envelope("0 chats")
    runner.stub "api get /my/boosts.json", stdout: empty_envelope("0 boosts")

    cli = build_cli(runner)

    assert_equal [], cli.chat_lines(project: 222, chat: 333, limit: 25)
    assert_equal [], cli.chats(project: 222)
    assert_equal [], cli.received_boosts(profile: "clawdito")
  end

  def test_chat_line_fetches_one_line_by_url
    runner = FakeCommandRunner.new
    runner.stub "chat line ", stdout: envelope(chat_line)

    line = build_cli(runner).chat_line("https://example.org/lines/91001.json")

    assert_equal 91001, line.fetch("id")
    assert_includes runner.commands.first.join(" "), "chat line https://example.org/lines/91001.json"
  end
end
