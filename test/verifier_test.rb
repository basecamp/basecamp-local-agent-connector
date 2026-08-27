require "test_helper"

class VerifierTest < Minitest::Test
  def test_verifies_corroborated_event
    runner = FakeCommandRunner.new
    runner.stub "basecamp show", stdout: envelope(sample_recording)

    verified = verifier(runner).verify(event(sample_payload))

    refute_nil verified
    assert_equal 456, verified.recording["id"]
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

  def test_corroborates_a_chat_line_through_the_chat_line_command
    runner = FakeCommandRunner.new
    runner.stub "chat line ", stdout: envelope(chat_line)

    verified = verifier(runner).verify(event(chat_line_payload))

    refute_nil verified
    assert_equal 91001, verified.recording["id"]
    assert_empty runner.commands_matching(/basecamp show/)
  end

  def test_rejects_a_chat_line_whose_authoritative_author_does_not_match
    runner = FakeCommandRunner.new
    runner.stub "chat line ", stdout: envelope(chat_line("creator" => { "id" => 999 }))

    assert_nil verifier(runner).verify(event(chat_line_payload))
  end

  def test_stamps_subscribed_after_confirming_the_agent_subscribes_to_the_comments_parent
    runner = FakeCommandRunner.new
    runner.stub "basecamp show", stdout: envelope(sample_recording("content" => "<p>no mention, just a note</p>"))
    runner.stub "subscriptions show", stdout: subscribers_envelope(200)

    verified = verifier(runner).verify(event(sample_payload))

    refute_nil verified
    assert verified.subscribed?
    # subscription is checked on the comment's parent recording, not the comment
    assert_includes runner.commands_matching(/subscriptions show/).first.join(" "), "cards/789"
  end

  def test_does_not_stamp_subscribed_when_the_agent_is_not_a_subscriber
    runner = FakeCommandRunner.new
    runner.stub "basecamp show", stdout: envelope(sample_recording("content" => "<p>no mention</p>"))
    runner.stub "subscriptions show", stdout: subscribers_envelope(999)

    verified = verifier(runner).verify(event(sample_payload))

    refute_nil verified
    refute verified.subscribed?
  end

  def test_a_mentioning_comment_needs_no_subscribers_lookup
    runner = FakeCommandRunner.new
    runner.stub "basecamp show", stdout: envelope(sample_recording)

    verified = verifier(runner).verify(event(sample_payload))

    refute_nil verified
    refute verified.subscribed?
    assert_empty runner.commands_matching(/subscriptions show/)
  end

  def test_a_failed_subscribers_lookup_stamps_not_subscribed
    runner = FakeCommandRunner.new
    runner.stub "basecamp show", stdout: envelope(sample_recording("content" => "<p>no mention</p>"))
    runner.stub "subscriptions show", exit_status: 1, stderr: "boom"

    verified = verifier(runner).verify(event(sample_payload))

    refute_nil verified
    refute verified.subscribed?
  end

  private
    def verifier(runner)
      BasecampAgentConnector::Basecamp::Verifier.new(basecamp_cli: build_cli(runner), agent: agent_identity)
    end

    def event(payload)
      BasecampAgentConnector::Basecamp::Event.from_payload(payload)
    end
end
