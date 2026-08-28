require "test_helper"

class PipelineTest < Minitest::Test
  def setup
    @operator = operator_identity
    @agent = agent_identity
    @output = StringIO.new
    @logs = StringIO.new
  end

  def test_emits_one_line_for_a_trusted_event
    runner = corroborating_runner
    pipeline(runner).process(sample_payload)

    assert_equal 1, @output.string.lines.length
    assert_equal 99001, JSON.parse(@output.string)["event_id"]
  end

  def test_dedupes_repeated_event_id
    runner = corroborating_runner
    pipeline = pipeline(runner)

    pipeline.process(sample_payload)
    pipeline.process(sample_payload)

    assert_equal 1, @output.string.lines.length
  end

  def test_ignores_event_from_a_non_operator
    runner = FakeCommandRunner.new

    pipeline(runner).process(sample_payload("creator" => { "email_address" => "someone@example.com" }))

    assert_empty @output.string
    assert_empty runner.commands
  end

  def test_ignores_non_actionable_kind
    pipeline(FakeCommandRunner.new).process(sample_payload("kind" => "comment_archived"))

    assert_empty @output.string
  end

  def test_ignores_a_comment_that_neither_mentions_nor_subscribes_the_agent
    recording = sample_recording("content" => "<p>just a normal comment, no mention</p>")
    runner = FakeCommandRunner.new
    runner.stub "basecamp show", stdout: envelope(recording)
    runner.stub "subscriptions show", stdout: subscribers_envelope(999)

    pipeline(runner).process(sample_payload("recording" => recording))

    assert_empty @output.string
    assert_match(/does not target the agent/, @logs.string)
  end

  def test_emits_for_a_comment_on_a_recording_the_agent_subscribes_to
    recording = sample_recording("content" => "<p>no mention, just an update</p>")
    runner = FakeCommandRunner.new
    runner.stub "basecamp show", stdout: envelope(recording)
    runner.stub "subscriptions show", stdout: subscribers_envelope(200)

    pipeline(runner).process(sample_payload("recording" => recording))

    assert_equal 1, @output.string.lines.length
    assert_equal "comment_created", JSON.parse(@output.string)["kind"]
  end

  def test_ignores_the_agents_own_comment_on_a_subscribed_recording
    author = { "id" => 200, "name" => "Clawdito", "email_address" => "clawdito@example.com" }
    recording = sample_recording("content" => "<p>my own reply</p>", "creator" => author)
    runner = FakeCommandRunner.new

    pipeline(runner).process(sample_payload("creator" => author, "recording" => recording))

    assert_empty @output.string
    assert_empty runner.commands
  end

  def test_ignores_a_third_partys_comment_on_a_subscribed_recording
    author = { "id" => 400, "email_address" => "sam@elsewhere.net" }
    recording = sample_recording("content" => "<p>hi</p>", "creator" => author)
    runner = FakeCommandRunner.new

    pipeline(runner).process(sample_payload("creator" => author, "recording" => recording))

    assert_empty @output.string
    assert_empty runner.commands
  end

  def test_a_forged_comment_kind_pointing_at_a_subscribed_message_cannot_emit
    # The POST claims comment_created but names an existing subscribed Message
    # the operator authored. Creator corroborates and the agent even subscribes,
    # but the authoritative recording is not a Comment, so nothing is emitted.
    message = sample_recording("type" => "Message", "content" => "<p>an old message, no mention</p>")
    runner = FakeCommandRunner.new
    runner.stub "basecamp show", stdout: envelope(message)
    runner.stub "subscriptions show", stdout: subscribers_envelope(200)

    pipeline(runner).process(sample_payload("recording" => message))

    assert_empty @output.string
    assert_match(/does not target the agent/, @logs.string)
    assert_empty runner.commands_matching(/subscriptions show/)
  end

  def test_a_forged_subscribed_flag_in_the_payload_cannot_emit
    # The POST claims agent_subscribed=true, but the agent is not really a
    # subscriber. The verifier discards the claimed flag and stamps its own from
    # the live subscribers API, so the event is dropped, not emitted.
    recording = sample_recording("content" => "<p>no mention</p>")
    runner = FakeCommandRunner.new
    runner.stub "basecamp show", stdout: envelope(recording)
    runner.stub "subscriptions show", stdout: subscribers_envelope(999)

    pipeline(runner).process(sample_payload("agent_subscribed" => true, "recording" => recording))

    assert_empty @output.string
    assert_match(/does not target the agent/, @logs.string)
  end

  def test_drops_uncorroborated_event
    runner = FakeCommandRunner.new
    runner.stub "basecamp show", stdout: envelope(sample_recording("creator" => { "id" => 999 }))

    pipeline = pipeline(runner)

    refute pipeline.process(sample_payload)
    assert_empty @output.string
    assert_match(/not corroborated/, @logs.string)
  end

  def test_an_uncorroborated_event_is_retried_when_delivered_again
    runner = FakeCommandRunner.new
    runner.stub "basecamp show", exit_status: 2, stdout: error_envelope("not_found", "Resource not found"), once: true
    runner.stub "basecamp show", stdout: envelope(sample_recording)
    pipeline = pipeline(runner)

    refute pipeline.process(sample_payload)
    assert pipeline.process(sample_payload)

    assert_equal 1, @output.string.lines.length
  end

  # One lost keyring probe must cost nothing visible: the client's retry
  # absorbs it, the event settles on this delivery, and the redelivery
  # Basecamp would send anyway is a duplicate.
  def test_an_event_corroborated_after_one_transient_failure_is_emitted_exactly_once
    runner = FakeCommandRunner.new
    runner.stub "basecamp show", exit_status: 3, once: true,
      stdout: error_envelope("auth_required", "Not authenticated for profile:clawdito: credentials not found")
    runner.stub "basecamp show", stdout: envelope(sample_recording)
    pipeline = pipeline(runner)

    assert pipeline.process(sample_payload)
    assert pipeline.process(sample_payload)

    assert_equal 1, @output.string.lines.length
    assert_equal 2, runner.commands_matching(/basecamp show/).length
    refute_match(/not corroborated/, @logs.string)
  end

  # A failure that outlasts the retries is no verdict: it propagates (for the
  # webhook handler to answer 503) rather than logging "not corroborated",
  # and forgets the id so the redelivery is verified afresh — and emitted
  # exactly once.
  def test_a_transient_failure_that_outlasts_the_retries_propagates_and_forgets_the_event
    runner = FakeCommandRunner.new
    stub_transient_failure runner, "basecamp show"
    runner.stub "basecamp show", stdout: envelope(sample_recording)
    pipeline = pipeline(runner)

    assert_raises(BasecampAgentConnector::Basecamp::Client::TransientError) { pipeline.process(sample_payload) }
    assert_empty @output.string
    refute_match(/not corroborated/, @logs.string)

    assert pipeline.process(sample_payload)
    assert pipeline.process(sample_payload)

    assert_equal 1, @output.string.lines.length
  end

  def test_a_settled_event_reports_a_verdict
    runner = FakeCommandRunner.new
    runner.stub "basecamp show", stdout: envelope(sample_recording)
    pipeline = pipeline(runner)

    assert pipeline.process(sample_payload)
    assert pipeline.process(sample_payload)
    assert pipeline.process(sample_payload("kind" => "comment_archived"))
    assert_equal 1, @output.string.lines.length
  end

  # The interleaving the pipeline's lock prevents: a verification overruns
  # bc3's delivery timeout, the redelivery arrives while it is in flight, and
  # the original then fails. Answered 200 as a duplicate, the redelivery
  # would have been the last one; waiting, it becomes the fresh attempt.
  def test_a_redelivery_during_an_in_flight_verification_waits_for_its_outcome
    gate = Queue.new
    runner = FakeCommandRunner.new
    stub_transient_failure runner, "basecamp show"
    runner.stub "basecamp show", stdout: envelope(sample_recording)
    gated = Object.new
    gated.define_singleton_method(:run) { |*command| gate.pop; runner.run(*command) }
    pipeline = pipeline(gated)
    original = Thread.new { pipeline.process(sample_payload) rescue $! }
    Thread.pass until original.status == "sleep"

    redelivery = Thread.new { pipeline.process(sample_payload) }
    4.times { gate << :go }

    assert_kind_of BasecampAgentConnector::Basecamp::Client::TransientError, original.value
    assert redelivery.value
    assert_equal 1, @output.string.lines.length
  end

  def test_emits_for_a_boost_on_the_agents_work_by_the_operator
    runner = FakeCommandRunner.new
    runner.stub "api get /my/boosts.json", stdout: envelope([ received_boost ])

    pipeline(runner).process(boost_payload)

    emitted = JSON.parse(@output.string)
    assert_equal 88001, emitted["event_id"]
    assert_equal "boost_created", emitted["kind"]
    assert_equal "🔥", emitted["details"]["boost"]["content"]
  end

  def test_the_emitted_boost_is_the_fetched_one_not_the_claimed_one
    runner = FakeCommandRunner.new
    runner.stub "api get /my/boosts.json", stdout: envelope([ received_boost ])

    pipeline(runner).process(boost_payload(received_boost("content" => "forged claim")))

    assert_equal "🔥", JSON.parse(@output.string)["details"]["boost"]["content"]
  end

  def test_a_forged_boosted_flag_in_the_payload_cannot_emit
    runner = FakeCommandRunner.new
    runner.stub "basecamp show", stdout: envelope(sample_recording("content" => "<p>no mention</p>"))
    runner.stub "subscriptions show", stdout: subscribers_envelope(999)

    payload = sample_payload("recording" => sample_recording("content" => "<p>no mention</p>"), "agent_boosted" => true)
    pipeline(runner).process(payload)

    assert_empty @output.string
    assert_match(/does not target the agent/, @logs.string)
  end

  def test_drops_a_boost_basecamp_no_longer_reports
    runner = FakeCommandRunner.new
    runner.stub "api get /my/boosts.json", stdout: envelope([])
    pipeline = pipeline(runner)

    refute pipeline.process(boost_payload)
    assert_empty @output.string
    assert_match(/not corroborated/, @logs.string)
  end

  def test_ignores_a_boost_from_an_unauthorized_booster_without_fetching
    runner = FakeCommandRunner.new

    pipeline(runner).process(boost_payload(received_boost("booster" => { "id" => 400, "email_address" => "sam@elsewhere.net" })))

    assert_empty @output.string
    assert_empty runner.commands
  end

  def test_ignores_the_agents_own_boost_without_fetching
    runner = FakeCommandRunner.new

    pipeline(runner).process(boost_payload(received_boost("booster" => { "id" => 200, "email_address" => "clawdito@example.com" })))

    assert_empty @output.string
    assert_empty runner.commands
  end

  # Email-keyed trust modes reach boosts only when the agent can see the
  # booster's address (bc3 redacts emails from non-admin viewers), so this
  # models an agent allowed to see it.
  def test_an_authorized_colleagues_boost_emits_under_domain_trust
    runner = FakeCommandRunner.new
    booster = { "id" => 300, "name" => "Marie", "email_address" => "marie@example.com" }
    runner.stub "api get /my/boosts.json", stdout: envelope([ received_boost("booster" => booster) ])

    pipeline(runner, authorizer: authorizer(trust: :domain, domains: [ "example.com" ])).process \
      boost_payload(received_boost("booster" => booster))

    assert_equal "marie@example.com", JSON.parse(@output.string)["creator"]["email_address"]
  end

  def test_a_redacted_colleagues_boost_cannot_authorize_email_keyed_trust
    redacted = { "id" => 300, "name" => "Marie", "email_address" => "m••••@•••••••.•••" }
    runner = FakeCommandRunner.new
    runner.stub "api get /my/boosts.json", stdout: envelope([ received_boost("booster" => redacted) ])

    pipeline(runner, authorizer: authorizer(trust: :allowlist, emails: [ "marie@example.com" ])).process \
      boost_payload(received_boost("booster" => redacted))

    assert_empty @output.string
  end

  def test_emits_for_an_assignment_of_the_agent_by_the_operator
    runner = FakeCommandRunner.new
    runner.stub "basecamp show", stdout: envelope(assigned_recording)

    pipeline(runner).process(assignment_payload)

    assert_equal 1, @output.string.lines.length
    assert_equal "kanban_card_assignment_changed", JSON.parse(@output.string)["kind"]
  end

  def test_ignores_an_assignment_made_by_a_non_operator
    runner = FakeCommandRunner.new

    pipeline(runner).process(assignment_payload("creator" => { "email_address" => "someone@example.com" }))

    assert_empty @output.string
    assert_empty runner.commands
  end

  def test_ignores_an_assignment_that_does_not_add_the_agent
    pipeline(FakeCommandRunner.new).process(assignment_payload("details" => { "added_person_ids" => [ 999 ] }))

    assert_empty @output.string
  end

  def test_drops_event_whose_claimed_author_is_not_the_authoritative_one
    # The POST claims the operator's email on the real author's Person id; the
    # corroborated creator (Sam) is who must be authorized, and isn't.
    runner = FakeCommandRunner.new
    runner.stub "basecamp show", stdout: envelope(sample_recording("creator" => { "id" => 400, "name" => "Sam", "email_address" => "sam@elsewhere.net" }))

    pipeline(runner).process(sample_payload("creator" => { "id" => 400, "name" => "Sam", "email_address" => "operator@example.com" }))

    assert_empty @output.string
    assert_match(/authoritative author is not authorized/, @logs.string)
  end

  def test_drops_a_forged_mention_when_the_authoritative_recording_has_none
    # The POST claims a mention of the agent (passing the pre-filter) but points
    # at a real operator recording that never mentioned the agent. The verified
    # recording is authoritative and carries no mention, so it must not emit.
    runner = FakeCommandRunner.new
    runner.stub "basecamp show", stdout: envelope(sample_recording("content" => "<p>a plain operator note, no mention</p>"))
    runner.stub "subscriptions show", stdout: subscribers_envelope(999)

    pipeline(runner).process(sample_payload)

    assert_empty @output.string
    assert_match(/does not target the agent/, @logs.string)
  end

  def test_allowlist_emits_for_an_allowed_author
    runner = FakeCommandRunner.new
    runner.stub "basecamp show", stdout: envelope(sample_recording("creator" => colleague))

    pipeline(runner, authorizer: authorizer(trust: :allowlist, emails: [ "marie@example.com" ]))
      .process(sample_payload("creator" => colleague))

    assert_equal 1, @output.string.lines.length
    assert_equal "marie@example.com", JSON.parse(@output.string)["creator"]["email_address"]
  end

  def test_allowlist_ignores_an_author_not_on_the_list
    runner = FakeCommandRunner.new

    pipeline(runner, authorizer: authorizer(trust: :allowlist, emails: [ "marie@example.com" ]))
      .process(sample_payload("creator" => { "id" => 400, "email_address" => "sam@elsewhere.net" }))

    assert_empty @output.string
    assert_empty runner.commands
  end

  def test_project_trust_emits_for_any_corroborated_author
    runner = FakeCommandRunner.new
    runner.stub "basecamp show", stdout: envelope(sample_recording("creator" => colleague))

    pipeline(runner, authorizer: authorizer(trust: :project)).process(sample_payload("creator" => colleague))

    assert_equal 1, @output.string.lines.length
  end

  def test_project_trust_drops_an_author_basecamp_marks_as_a_client
    runner = FakeCommandRunner.new
    runner.stub "basecamp show", stdout: envelope(sample_recording("creator" => colleague.merge("client" => true)))

    pipeline(runner, authorizer: authorizer(trust: :project)).process(sample_payload("creator" => colleague))

    assert_empty @output.string
    assert_match(/authoritative author is not authorized/, @logs.string)
  end

  def test_project_trust_ignores_an_event_authored_by_the_agent_itself
    runner = FakeCommandRunner.new

    # client=>false so the drop is the Person-id self-exclusion guard, not the
    # fail-closed client check masking a regression in it.
    pipeline(runner, authorizer: authorizer(trust: :project))
      .process(sample_payload("creator" => { "id" => 200, "name" => "Clawdito", "email_address" => "clawdito@example.com", "client" => false }))

    assert_empty @output.string
    assert_empty runner.commands
  end

  def test_domain_trust_emits_for_a_matching_domain
    runner = FakeCommandRunner.new
    runner.stub "basecamp show", stdout: envelope(sample_recording("creator" => colleague))

    pipeline(runner, authorizer: authorizer(trust: :domain, domains: [ "example.com" ]))
      .process(sample_payload("creator" => colleague))

    assert_equal 1, @output.string.lines.length
  end

  def test_domain_trust_ignores_other_domains
    runner = FakeCommandRunner.new

    pipeline(runner, authorizer: authorizer(trust: :domain, domains: [ "example.com" ]))
      .process(sample_payload("creator" => { "id" => 400, "email_address" => "sam@elsewhere.net" }))

    assert_empty @output.string
    assert_empty runner.commands
  end

  def test_domain_trust_ignores_the_agent_itself_on_a_shared_domain
    runner = FakeCommandRunner.new

    pipeline(runner, authorizer: authorizer(trust: :domain, domains: [ "example.com" ]))
      .process(sample_payload("creator" => { "id" => 200, "name" => "Clawdito", "email_address" => "clawdito@example.com" }))

    assert_empty @output.string
    assert_empty runner.commands
  end

  def test_allowlist_emits_for_an_allowed_authors_comment_on_a_subscribed_recording
    # The subscription trigger passes the same trust gate as a mention: a
    # broadened mode's authors can drive the agent through a followed thread.
    recording = sample_recording("content" => "<p>no mention, just an update</p>", "creator" => colleague)
    runner = FakeCommandRunner.new
    runner.stub "basecamp show", stdout: envelope(recording)
    runner.stub "subscriptions show", stdout: subscribers_envelope(200)

    pipeline(runner, authorizer: authorizer(trust: :allowlist, emails: [ "marie@example.com" ]))
      .process(sample_payload("creator" => colleague, "recording" => recording))

    assert_equal 1, @output.string.lines.length
    assert_equal "marie@example.com", JSON.parse(@output.string)["creator"]["email_address"]
  end

  def test_project_trust_drops_a_client_authors_comment_on_a_subscribed_recording
    # Subscription targeting never bypasses the authorizer: even when the agent
    # really subscribes, the corroborated author must still be authorized. The
    # claimed payload denies client status (passing the pre-filter); Basecamp's
    # authoritative copy marks the author a client, and that copy decides.
    recording = sample_recording("content" => "<p>no mention</p>", "creator" => colleague.merge("client" => true))
    runner = FakeCommandRunner.new
    runner.stub "basecamp show", stdout: envelope(recording)
    runner.stub "subscriptions show", stdout: subscribers_envelope(200)

    pipeline(runner, authorizer: authorizer(trust: :project))
      .process(sample_payload("creator" => colleague, "recording" => recording))

    assert_empty @output.string
    assert_match(/authoritative author is not authorized/, @logs.string)
  end

  def test_broadened_trust_keeps_assignments_operator_only
    runner = FakeCommandRunner.new

    pipeline(runner, authorizer: authorizer(trust: :allowlist, emails: [ "marie@example.com" ]))
      .process(assignment_payload("creator" => colleague))

    assert_empty @output.string
    assert_empty runner.commands
  end

  def test_assignment_opt_in_lets_an_authorized_author_assign
    runner = FakeCommandRunner.new
    runner.stub "basecamp show", stdout: envelope(assigned_recording)

    pipeline(runner, authorizer: authorizer(trust: :allowlist, emails: [ "marie@example.com" ], allow_assignments: true))
      .process(assignment_payload("creator" => colleague))

    assert_equal 1, @output.string.lines.length
  end

  private
    def colleague
      { "id" => 300, "name" => "Marie", "email_address" => "marie@example.com", "client" => false }
    end

    def corroborating_runner
      runner = FakeCommandRunner.new
      runner.stub "basecamp show", stdout: envelope(sample_recording)
      runner
    end

    def pipeline(runner, authorizer: authorizer())
      BasecampAgentConnector::Basecamp::Pipeline.new \
        authorizer: authorizer,
        agent: @agent,
        verifier: BasecampAgentConnector::Basecamp::Verifier.new(basecamp_cli: build_cli(runner), agent: @agent),
        emitter: BasecampAgentConnector::Emitter.new(output: @output),
        logger: @logs
    end
end
