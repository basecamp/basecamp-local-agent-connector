require "test_helper"

class PipelineTest < Minitest::Test
  def setup
    @identity = BasecampAgentConnector::Identity.new(id: 123)
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

  def test_ignores_event_from_another_user
    runner = FakeCommandRunner.new

    pipeline(runner).process(sample_payload("creator" => { "id" => 999 }))

    assert_empty @output.string
    assert_empty runner.commands
  end

  def test_ignores_non_actionable_kind
    pipeline(FakeCommandRunner.new).process(sample_payload("kind" => "comment_archived"))

    assert_empty @output.string
  end

  def test_ignores_event_without_the_trigger
    payload = sample_payload
    payload["recording"]["content"] = "<div>just a normal comment</div>"

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

  private
    def corroborating_runner
      runner = FakeCommandRunner.new
      runner.stub "basecamp show", stdout: envelope(sample_recording)
      runner
    end

    def pipeline(runner)
      BasecampAgentConnector::Pipeline.new \
        trigger: "@agent",
        identity: @identity,
        verifier: BasecampAgentConnector::Verifier.new(basecamp_cli: build_cli(runner)),
        emitter: BasecampAgentConnector::Emitter.new(output: @output),
        logger: @logs
    end
end
