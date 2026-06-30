require "test_helper"

class ReviewPipelineTest < Minitest::Test
  def setup
    @secret = "s3cret"
    @output = StringIO.new
    @logs = StringIO.new
  end

  def test_emits_one_line_for_a_signed_actionable_review
    body = JSON.generate(review_payload)

    pipeline(corroborating_runner).process(body: body, signature: sign(body, @secret))

    assert_equal 1, @output.string.lines.length
    assert_equal 7001, JSON.parse(@output.string)["review_id"]
  end

  def test_rejects_a_delivery_with_a_bad_signature
    runner = FakeCommandRunner.new
    body = JSON.generate(review_payload)

    pipeline(runner).process(body: body, signature: sign(body, "wrong"))

    assert_empty @output.string
    assert_empty runner.commands
    assert_match(/invalid or missing signature/, @logs.string)
  end

  def test_dedupes_a_repeated_review
    body = JSON.generate(review_payload)
    pipeline = pipeline(corroborating_runner)

    pipeline.process(body: body, signature: sign(body, @secret))
    pipeline.process(body: body, signature: sign(body, @secret))

    assert_equal 1, @output.string.lines.length
  end

  def test_ignores_a_non_actionable_state
    body = JSON.generate(review_payload("review" => review_hash("state" => "pending")))

    pipeline(FakeCommandRunner.new).process(body: body, signature: sign(body, @secret))

    assert_empty @output.string
  end

  def test_drops_an_uncorroborated_review
    runner = FakeCommandRunner.new
    runner.stub(%r{reviews/7001$}, exit_status: 1, stderr: "Not Found")
    body = JSON.generate(review_payload)

    pipeline(runner).process(body: body, signature: sign(body, @secret))

    assert_empty @output.string
    assert_match(/not corroborated/, @logs.string)
  end

  private
    def corroborating_runner
      runner = FakeCommandRunner.new
      runner.stub(%r{reviews/7001$}, stdout: JSON.generate(review_hash))
      runner.stub "reviews/7001/comments", stdout: "[]"
      runner
    end

    def pipeline(runner)
      BasecampAgentConnector::ReviewPipeline.new \
        secret: @secret,
        verifier: BasecampAgentConnector::ReviewVerifier.new(github_cli: build_github_cli(runner)),
        emitter: BasecampAgentConnector::Emitter.new(output: @output),
        logger: @logs
    end
end
