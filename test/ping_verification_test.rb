require "test_helper"

# The trust boundary for a ping. A mention decides it everywhere else; here the
# conversation's membership does, so these are the tests that say what may reach
# an agent.
class PingVerificationTest < Minitest::Test
  Event = BasecampAgentConnector::Basecamp::Event
  Verifier = BasecampAgentConnector::Basecamp::Verifier

  def setup
    @operator = operator_identity(person_id: 100)
    @agent = agent_identity
  end

  def test_a_ping_is_told_apart_by_its_kind_and_its_bucket
    assert Event.from_payload(ping_payload).ping?
    refute Event.from_payload(sample_payload).ping?
  end

  # A comment whose kind was forged to look like a ping is still a comment: the
  # bucket it really lives in is a Project, and that is not a conversation.
  def test_a_kind_alone_does_not_make_something_a_ping
    forged = ping_payload("recording" => ping_line("bucket" => { "id" => 222, "type" => "Project" }))

    refute Event.from_payload(forged).ping?
  end

  def test_a_conversation_between_the_two_of_them_is_corroborated
    runner = FakeCommandRunner.new
    stub_line runner, ping_line
    stub_subscribers runner, [ 100, 200 ]

    assert verify(runner, ping_payload)
  end

  # The check that stands in for a mention. A third participant makes the reply
  # the agent would post land in front of somebody who never asked for it.
  def test_a_conversation_with_a_third_participant_is_refused
    runner = FakeCommandRunner.new
    stub_line runner, ping_line
    stub_subscribers runner, [ 100, 200, 300 ]

    assert_nil verify(runner, ping_payload)
  end

  def test_a_conversation_the_agent_is_not_in_is_refused
    runner = FakeCommandRunner.new
    stub_line runner, ping_line
    stub_subscribers runner, [ 100, 300 ]

    assert_nil verify(runner, ping_payload)
  end

  def test_a_line_whose_author_does_not_match_the_claim_is_refused
    runner = FakeCommandRunner.new
    stub_line runner, agent_line
    stub_subscribers runner, [ 100, 200 ]

    assert_nil verify(runner, ping_payload)
  end

  # `show` rewrites a line's URL to `recordings/<id>.json`, which resolves to
  # nothing. Reading a ping through it corroborated nothing and dropped every one.
  def test_a_ping_is_read_through_the_raw_api_and_never_through_show
    runner = FakeCommandRunner.new
    stub_line runner, ping_line
    stub_subscribers runner, [ 100, 200 ]

    verify runner, ping_payload

    assert_empty runner.commands_matching(/basecamp show/)
  end

  def test_a_participant_read_that_could_not_be_made_is_retryable
    runner = FakeCommandRunner.new
    stub_line runner, ping_line
    runner.stub "api get #{ping_circle.subscription_path}", stderr: "timed out", exit_status: 1

    assert_raises(Verifier::Unreachable) { verify(runner, ping_payload) }
  end

  def test_the_operators_ping_is_actionable_without_a_mention
    assert_equal 1, emitted(ping_payload).length
  end

  def test_somebody_elses_ping_is_not_actionable
    assert_empty emitted(ping_payload("creator" => { "id" => 300, "name" => "Someone" },
      "recording" => ping_line("creator" => { "id" => 300, "name" => "Someone" })))
  end

  private
    def verify(runner, payload)
      Verifier.new(basecamp_cli: build_cli(runner), agent: @agent, operator: @operator)
        .verify(Event.from_payload(payload))
    end

    def emitted(payload)
      output = StringIO.new
      runner = FakeCommandRunner.new
      stub_line runner, payload["recording"]
      stub_subscribers runner, [ 100, 200 ]

      BasecampAgentConnector::Basecamp::Pipeline.new(
        operator: @operator, agent: @agent, logger: StringIO.new,
        verifier: Verifier.new(basecamp_cli: build_cli(runner), agent: @agent, operator: @operator),
        emitter: BasecampAgentConnector::Emitter.new(output: output)).process(payload)

      output.string.lines
    end
end
