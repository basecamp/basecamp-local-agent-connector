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

    pipeline(runner).process(sample_payload)

    assert_empty @output.string
    assert_match(/not corroborated/, @logs.string)
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

  def test_emits_a_card_created_in_a_watched_column_with_no_operator_involvement
    runner = FakeCommandRunner.new
    runner.stub "basecamp show", stdout: envelope(created_card_recording)

    pipeline(runner, watched_columns: [ watched_column ]).process(card_created_payload)

    assert_equal 1, @output.string.lines.length
    assert_equal "kanban_card_created", JSON.parse(@output.string)["kind"]
  end

  def test_ignores_a_card_created_in_a_watched_column_when_no_column_is_watched
    pipeline(FakeCommandRunner.new).process(card_created_payload)

    assert_empty @output.string
  end

  def test_ignores_a_card_created_in_another_column
    payload = card_created_payload
    payload["recording"]["parent"] = { "id" => 999, "title" => "Triage", "type" => "Kanban::Column" }

    pipeline(FakeCommandRunner.new, watched_columns: [ watched_column ]).process(payload)

    assert_empty @output.string
  end

  def test_ignores_a_card_created_in_the_watched_column_by_another_creator
    payload = card_created_payload("creator" => { "id" => 888, "email_address" => "someone@example.com" })

    pipeline(FakeCommandRunner.new, watched_columns: [ watched_column ]).process(payload)

    assert_empty @output.string
  end

  # The widening covers one column. A comment elsewhere on the same board still
  # needs the operator to author it and to point it at the agent.
  def test_still_ignores_a_non_operator_comment_when_a_column_is_watched
    payload = sample_payload("creator" => { "email_address" => "someone@example.com" })

    pipeline(FakeCommandRunner.new, watched_columns: [ watched_column ]).process(payload)

    assert_empty @output.string
  end

  def test_drops_an_uncorroborated_card_created_in_a_watched_column
    runner = FakeCommandRunner.new
    runner.stub "basecamp show", stdout: envelope(created_card_recording("creator" => { "id" => 999 }))

    pipeline(runner, watched_columns: [ watched_column ]).process(card_created_payload)

    assert_empty @output.string
    assert_match(/not corroborated/, @logs.string)
  end

  private
    def watched_column
      BasecampAgentConnector::Basecamp::WatchedColumn.parse("222:555:777")
    end

    def corroborating_runner
      runner = FakeCommandRunner.new
      runner.stub "basecamp show", stdout: envelope(sample_recording)
      runner
    end

    def pipeline(runner, watched_columns: [])
      BasecampAgentConnector::Basecamp::Pipeline.new \
        operator: @operator,
        agent: @agent,
        verifier: BasecampAgentConnector::Basecamp::Verifier.new(basecamp_cli: build_cli(runner), agent: @agent),
        emitter: BasecampAgentConnector::Emitter.new(output: @output),
        watched_columns: watched_columns,
        logger: @logs
    end
end
