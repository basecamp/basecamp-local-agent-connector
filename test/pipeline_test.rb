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

  def test_ignores_event_that_does_not_mention_the_agent
    payload = sample_payload
    payload["recording"]["content"] = "<p>just a normal comment, no mention</p>"

    pipeline(FakeCommandRunner.new).process(payload)

    assert_empty @output.string
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
    runner.stub "basecamp show", exit_status: 1, stderr: "502 Bad Gateway", once: true
    runner.stub "basecamp show", stdout: envelope(sample_recording)
    pipeline = pipeline(runner)

    refute pipeline.process(sample_payload)
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
    runner = FakeCommandRunner.new
    runner.stub "basecamp show", stdout: envelope(sample_recording("creator" => { "id" => 100, "name" => "Sam", "email_address" => "sam@elsewhere.net" }))

    pipeline(runner).process(sample_payload)

    assert_empty @output.string
    assert_match(/authoritative author is not authorized/, @logs.string)
  end

  def test_drops_a_forged_mention_when_the_authoritative_recording_has_none
    # The POST claims a mention of the agent (passing the pre-filter) but points
    # at a real operator recording that never mentioned the agent. The verified
    # recording is authoritative and carries no mention, so it must not emit.
    runner = FakeCommandRunner.new
    runner.stub "basecamp show", stdout: envelope(sample_recording("content" => "<p>a plain operator note, no mention</p>"))

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
