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

  private
    def verifier(runner)
      BasecampAgentConnector::Basecamp::Verifier.new(basecamp_cli: build_cli(runner), agent: agent_identity)
    end

    def event(payload)
      BasecampAgentConnector::Basecamp::Event.from_payload(payload)
    end
end
