require "test_helper"

class VerifierTest < Minitest::Test
  def test_verifies_corroborated_event
    runner = FakeCommandRunner.new
    runner.stub "basecamp show", stdout: envelope(sample_recording)

    verified = verifier(runner).verify(event(sample_payload))

    refute_nil verified
    assert_equal 456, verified.recording["id"]
  end

  # Corroboration asks Basecamp what is really there, and the answer depends on
  # who is asking. Reading as the CLI default made the check run as the OPERATOR:
  # it could corroborate a recording the agent's own identity cannot see, and it
  # gave the bridge an undeclared dependency on a second set of credentials. The
  # poller's five read paths were fixed for this; the Verifier was missed.
  def test_the_corroborating_read_is_made_as_the_agent
    runner = FakeCommandRunner.new
    runner.stub "basecamp show", stdout: envelope(sample_recording)

    verifier(runner).verify(event(sample_payload))

    reads = runner.commands_matching(/show/)
    refute_empty reads
    unprofiled = reads.reject { |command| command.each_cons(2).include?([ "--profile", "clawdito" ]) }
    assert_empty unprofiled, "corroboration must read as the agent: #{unprofiled.inspect}"
  end

  def test_rejects_when_creator_does_not_match
    runner = FakeCommandRunner.new
    runner.stub "basecamp show", stdout: envelope(sample_recording("creator" => { "id" => 999 }))

    assert_nil verifier(runner).verify(event(sample_payload))
  end

  def test_rejects_when_recording_not_found
    runner = FakeCommandRunner.new
    runner.stub "basecamp show", exit_status: 1, stderr: "not found"

    assert_nil verifier(runner).verify(event(sample_payload))
  end

  def test_does_not_call_basecamp_without_a_locator
    runner = FakeCommandRunner.new
    payload = sample_payload
    payload["recording"].delete("url")
    payload["recording"].delete("app_url")

    assert_nil verifier(runner).verify(event(payload))
    assert_empty runner.commands
  end

  def test_corroborates_an_assignment_when_the_agent_is_an_assignee
    runner = FakeCommandRunner.new
    runner.stub "basecamp show", stdout: envelope(assigned_recording)

    verified = verifier(runner).verify(event(assignment_payload))

    refute_nil verified
    assert_equal "kanban_card_assignment_changed", verified.kind
    # the assigner (operator), not the card's creator, stays as the event creator
    assert_equal 100, verified.creator_id
  end

  def test_rejects_an_assignment_when_the_agent_is_not_an_assignee
    runner = FakeCommandRunner.new
    runner.stub "basecamp show", stdout: envelope(assigned_recording("assignees" => [ { "id" => 999 } ]))

    assert_nil verifier(runner).verify(event(assignment_payload))
  end

  # `/x` discards literal whitespace, so every multi-word alternative in
  # UNREACHABLE matched nothing until 2026-08-26 -- a lost credential race, the
  # failure the class was built for, read as a forgery and was dropped.
  UNREACHABLE_MESSAGES = [
    "not authenticated for profile:on-call-bot",
    "credentials not found for profile:on-call-bot",
    "no such profile",
    "timed out",
    "timeout",
    "connection refused",
    "connection reset by peer",
    "could not connect",
    "network is down",
    "network is unreachable",
    "temporarily unavailable",
    "502 Bad Gateway"
  ].freeze

  def test_every_failure_that_means_the_question_never_landed_is_retryable
    UNREACHABLE_MESSAGES.each do |message|
      assert BasecampAgentConnector::Basecamp::Verifier::UNREACHABLE.match?(message),
        "#{message.inspect} must be treated as unreachable, not as a rejection"
    end
  end

  def test_a_real_absence_is_still_a_rejection
    refute BasecampAgentConnector::Basecamp::Verifier::UNREACHABLE.match?("Resource not found: https://example.com/x.json")
  end

  private
    def verifier(runner)
      BasecampAgentConnector::Basecamp::Verifier.new(basecamp_cli: build_cli(runner), agent: agent_identity)
    end

    def event(payload)
      BasecampAgentConnector::Basecamp::Event.from_payload(payload)
    end
end
