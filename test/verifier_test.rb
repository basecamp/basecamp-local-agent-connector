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

  def test_rejects_a_recording_basecamp_still_marks_a_draft
    runner = FakeCommandRunner.new
    runner.stub "basecamp show", stdout: envelope(published_message("status" => "drafted"))

    assert_nil verifier(runner).verify(event(draft_published_payload))
  end

  def test_verifies_a_recording_published_from_a_draft
    runner = FakeCommandRunner.new
    runner.stub "basecamp show", stdout: envelope(published_message)

    verified = verifier(runner).verify(event(draft_published_payload))

    refute_nil verified
    assert verified.mentioned?
  end

  def test_rejects_when_recording_not_found
    runner = FakeCommandRunner.new
    runner.stub "basecamp show", exit_status: 2, stdout: error_envelope("not_found", "Resource not found")

    assert_nil verifier(runner).verify(event(sample_payload))
    assert_equal 1, runner.commands.length
  end

  # No verdict without an answer: a fetch the CLI could not complete is not
  # "Basecamp says it isn't there", so it propagates instead of rejecting.
  def test_a_transient_fetch_failure_propagates_instead_of_rejecting
    runner = FakeCommandRunner.new
    stub_transient_failure runner, "basecamp show"

    assert_raises(BasecampAgentConnector::Basecamp::Client::TransientError) { verifier(runner).verify(event(sample_payload)) }
  end

  def test_a_transient_chat_line_fetch_failure_propagates_instead_of_rejecting
    runner = FakeCommandRunner.new
    stub_transient_failure runner, "chat line "

    assert_raises(BasecampAgentConnector::Basecamp::Client::TransientError) { verifier(runner).verify(event(chat_line_payload)) }
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

  def test_stamps_mentioned_from_the_authoritative_recording_not_the_claim
    runner = FakeCommandRunner.new
    runner.stub "basecamp show", stdout: envelope(sample_recording)

    # the POST's content mentions nobody; the re-fetched recording does
    verified = verifier(runner).verify(event(sample_payload("recording" => sample_recording("content" => "<p>no mention</p>"))))

    refute_nil verified
    assert verified.mentioned?
  end

  def test_does_not_stamp_mentioned_when_the_authoritative_recording_mentions_someone_else
    runner = FakeCommandRunner.new
    runner.stub "basecamp show", stdout: envelope(sample_recording("content" => "<p>#{mention_html(person_id: 999)}</p>"))
    runner.stub "subscriptions show", stdout: subscribers_envelope(200)

    verified = verifier(runner).verify(event(sample_payload))

    refute_nil verified
    refute verified.mentioned?
    assert verified.subscribed?
  end

  def test_does_not_stamp_subscribed_when_the_recording_is_not_a_comment
    # A forged comment_created pointing at a subscribed Message/Card: creator
    # corroborates, but the authoritative recording is not a Comment, so it is
    # not treated as a subscribed comment and no subscribers lookup is made.
    runner = FakeCommandRunner.new
    runner.stub "basecamp show", stdout: envelope(sample_recording("type" => "Message", "content" => "<p>an old message</p>"))

    verified = verifier(runner).verify(event(sample_payload))

    refute_nil verified
    refute verified.subscribed?
    assert_empty runner.commands_matching(/subscriptions show/)
  end

  def test_a_refused_subscribers_lookup_stamps_not_subscribed
    runner = FakeCommandRunner.new
    runner.stub "basecamp show", stdout: envelope(sample_recording("content" => "<p>no mention</p>"))
    runner.stub "subscriptions show", exit_status: 2, stdout: error_envelope("not_found", "Resource not found")

    verified = verifier(runner).verify(event(sample_payload))

    refute_nil verified
    refute verified.subscribed?
  end

  # Stamping "not subscribed" on a lookup that never got an answer would
  # settle the event as "does not target the agent" — a drop Basecamp never
  # redelivers. It propagates instead, like the recording fetch.
  def test_a_transient_subscribers_lookup_failure_propagates
    runner = FakeCommandRunner.new
    runner.stub "basecamp show", stdout: envelope(sample_recording("content" => "<p>no mention</p>"))
    stub_transient_failure runner, "subscriptions show"

    assert_raises(BasecampAgentConnector::Basecamp::Client::TransientError) { verifier(runner).verify(event(sample_payload)) }
  end

  def test_corroborates_a_boost_against_the_agents_own_feed_and_stamps_it
    runner = FakeCommandRunner.new
    runner.stub "api get /my/boosts.json", stdout: envelope([ received_boost("content" => "👏") ])

    verified = verifier(runner).verify(event(boost_payload))

    refute_nil verified
    assert verified.boosted?
    # The authoritative content is the fetched one, not the claimed one.
    assert_equal "👏", verified.details["boost"]["content"]
    assert_equal 456, verified.recording["id"]
    assert_includes runner.commands.first.join(" "), "--profile clawdito"
    assert_empty runner.commands_matching(/basecamp show/)
  end

  def test_rejects_a_boost_absent_from_the_agents_feed
    runner = FakeCommandRunner.new
    runner.stub "api get /my/boosts.json", stdout: envelope([ received_boost("id" => 77000) ])

    assert_nil verifier(runner).verify(event(boost_payload))
  end

  def test_rejects_a_boost_whose_authoritative_booster_does_not_match
    runner = FakeCommandRunner.new
    runner.stub "api get /my/boosts.json", stdout: envelope([ received_boost("booster" => { "id" => 999 }) ])

    assert_nil verifier(runner).verify(event(boost_payload))
  end

  def test_rejects_a_boost_when_the_feed_fetch_is_refused
    runner = FakeCommandRunner.new
    runner.stub "api get /my/boosts.json", exit_status: 4, stdout: error_envelope("forbidden", "Access denied")

    assert_nil verifier(runner).verify(event(boost_payload))
  end

  def test_a_transient_feed_fetch_failure_propagates_instead_of_rejecting
    runner = FakeCommandRunner.new
    stub_transient_failure runner, "api get /my/boosts.json"

    assert_raises(BasecampAgentConnector::Basecamp::Client::TransientError) { verifier(runner).verify(event(boost_payload)) }
  end

  def test_rejects_a_boost_when_the_agent_has_no_profile
    runner = FakeCommandRunner.new
    verifier = BasecampAgentConnector::Basecamp::Verifier.new \
      basecamp_cli: build_cli(runner),
      agent: BasecampAgentConnector::Basecamp::Identity.new(id: 200, email: "clawdito@example.com", person_id: 200)

    assert_nil verifier.verify(event(boost_payload))
    assert_empty runner.commands
  end

  # A ping corroborates on three things, all of them Basecamp's word: the
  # re-fetched line's author, the bucket it says it lives in, and who else is
  # in that room. Every call runs as the agent, because a Circle is served to
  # nobody else.
  def test_verifies_a_ping_line_in_a_room_private_to_the_agent_and_its_operator
    runner = ping_runner
    verified = ping_verifier(runner).verify(event(ping_line_payload))

    refute_nil verified
    assert_predicate verified, :pinged?
    refute_predicate verified, :mentioned?
    assert_includes runner.commands_matching(%r{lines/92001\.json}).first.join(" "), "--profile clawdito"
    assert_includes runner.commands_matching(%r{recordings/666/subscription\.json}).first.join(" "), "--profile clawdito"
  end

  # A third person makes it someone else's conversation too, and the reply the
  # agent posts lands in front of them.
  def test_refuses_a_ping_in_a_room_with_a_third_participant
    runner = ping_runner(subscribers: [ 100, 200, 400 ])

    refute_predicate ping_verifier(runner).verify(event(ping_line_payload)), :pinged?
  end

  # A room the agent is somehow not in is not a ping at the agent.
  def test_refuses_a_ping_the_agent_is_not_a_participant_in
    runner = ping_runner(subscribers: [ 100, 400 ])

    refute_predicate ping_verifier(runner).verify(event(ping_line_payload)), :pinged?
  end

  # The kind said ping; the re-fetch says project Campfire. Basecamp wins, and
  # the line goes back to owing the mention every Campfire line owes.
  def test_a_line_the_refetch_puts_in_a_campfire_is_not_corroborated_as_a_ping
    runner = ping_runner(line: ping_line("bucket" => { "id" => 222, "name" => "BC5 Calendar", "type" => "Project" }))

    assert_nil ping_verifier(runner).verify(event(ping_line_payload))
  end

  def test_drops_a_ping_line_deleted_between_poll_and_dispatch
    runner = FakeCommandRunner.new
    runner.stub "api get https://3.basecamp.com/000/buckets/555/chats/666/lines/92001.json",       exit_status: 2, stdout: error_envelope("not_found")

    assert_nil ping_verifier(runner).verify(event(ping_line_payload))
  end

  # A subscription lookup the CLI could not complete says nothing about the
  # room, so it propagates for the poller to retry rather than settling as
  # "not a ping".
  def test_a_transient_subscription_failure_propagates
    runner = FakeCommandRunner.new
    runner.stub "api get https://3.basecamp.com/000/buckets/555/chats/666/lines/92001.json", stdout: envelope(ping_line)
    stub_transient_failure runner, "api get /buckets/555/recordings/666/subscription.json"

    assert_raises(BasecampAgentConnector::Basecamp::Client::TransientError) do
      ping_verifier(runner).verify(event(ping_line_payload))
    end
  end

  # Without an operator there is nobody the room could be private *with*, so
  # nothing is stamped — and the room is not even asked about.
  def test_refuses_a_ping_when_no_operator_is_known
    runner = ping_runner
    verifier = BasecampAgentConnector::Basecamp::Verifier.new(basecamp_cli: build_cli(runner), agent: agent_identity)

    refute_predicate verifier.verify(event(ping_line_payload)), :pinged?
    assert_empty runner.commands_matching(%r{subscription\.json})
  end

  private
    def verifier(runner)
      BasecampAgentConnector::Basecamp::Verifier.new(basecamp_cli: build_cli(runner), agent: agent_identity)
    end

    # The verifier the connector builds: it knows the operator, which is what
    # a ping's privacy check is measured against.
    def ping_verifier(runner)
      BasecampAgentConnector::Basecamp::Verifier.new(basecamp_cli: build_cli(runner), agent: agent_identity,
        operator: operator_identity)
    end

    def ping_runner(line: ping_line, subscribers: [ 100, 200 ])
      runner = FakeCommandRunner.new
      runner.stub "api get https://3.basecamp.com/000/buckets/555/chats/666/lines/92001.json", stdout: envelope(line)
      runner.stub "api get /buckets/555/recordings/666/subscription.json", stdout: subscribers_envelope(*subscribers)
      runner
    end

    def event(payload)
      BasecampAgentConnector::Basecamp::Event.from_payload(payload)
    end
end
