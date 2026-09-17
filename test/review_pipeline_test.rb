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

  # Also the case the self-review drop must not touch: the operator's own
  # approval is the signal the whole loop rests on.
  def test_emits_the_operators_approval
    approval = review_hash("state" => "approved", "body" => "LGTM")
    body = JSON.generate(review_payload("review" => approval))

    pipeline(corroborating_runner(approval)).process(body: body, signature: sign(body, @secret))

    emitted = JSON.parse(@output.string)
    assert_equal "approved", emitted["state"]
    assert_equal "octocat", emitted["reviewer"]
  end

  def test_matches_the_operator_login_case_insensitively
    approval = review_hash("state" => "approved", "user" => { "login" => "OctoCat" })
    body = JSON.generate(review_payload("review" => approval))

    pipeline(corroborating_runner(approval)).process(body: body, signature: sign(body, @secret))

    assert_equal 1, @output.string.lines.length
  end

  def test_drops_another_reviewers_approval_without_asking_github
    runner = FakeCommandRunner.new
    body = JSON.generate(review_payload("review" => review_hash("state" => "approved", "user" => { "login" => "someone-else" })))

    pipeline(runner).process(body: body, signature: sign(body, @secret))

    assert_empty @output.string
    assert_empty runner.commands
    assert_match(/dropped review 7001: approved by "someone-else", not by the operator \(octocat\)/, @logs.string)
  end

  # The delivery body claims the operator approved; the review GitHub actually
  # recorded says otherwise. The authoritative reviewer decides.
  def test_drops_an_approval_whose_authoritative_reviewer_is_not_the_operator
    claimed = review_hash("state" => "approved")
    recorded = review_hash("state" => "approved", "user" => { "login" => "someone-else" })
    body = JSON.generate(review_payload("review" => claimed))

    pipeline(corroborating_runner(recorded)).process(body: body, signature: sign(body, @secret))

    assert_empty @output.string
    assert_match(/dropped review 7001: approved by "someone-else", not by the operator \(octocat\)/, @logs.string)
  end

  def test_drops_an_approval_whose_authoritative_reviewer_is_missing
    claimed = review_hash("state" => "approved")
    recorded = review_hash("state" => "approved", "user" => nil)
    body = JSON.generate(review_payload("review" => claimed))

    pipeline(corroborating_runner(recorded)).process(body: body, signature: sign(body, @secret))

    assert_empty @output.string
    assert_match(/approved by nil, not by the operator/, @logs.string)
  end

  def test_emits_another_reviewers_requested_changes
    review = review_hash("state" => "changes_requested", "user" => { "login" => "someone-else" })
    body = JSON.generate(review_payload("review" => review))

    pipeline(corroborating_runner(review)).process(body: body, signature: sign(body, @secret))

    emitted = JSON.parse(@output.string)
    assert_equal "changes_requested", emitted["state"]
    assert_equal "someone-else", emitted["reviewer"]
  end

  # Every dispatched agent commits and comments on GitHub under the operator's
  # own account, so a `commented` review by that login is the agent answering a
  # review thread on its own PR. Emitting it would wake a session to read
  # itself talking.
  def test_drops_the_operators_own_comment_review_without_asking_github
    runner = FakeCommandRunner.new
    body = JSON.generate(review_payload("review" => review_hash("state" => "commented", "body" => "addressed in 3f2a1c9")))

    pipeline(runner).process(body: body, signature: sign(body, @secret))

    assert_empty @output.string
    assert_empty runner.commands
    assert_match(/dropped review 7001: commented by the operator \(octocat\)/, @logs.string)
    assert_match(/--include-self-reviews/, @logs.string)
  end

  # The delivery body claims someone else commented; GitHub recorded the
  # operator. The authoritative reviewer decides here too.
  def test_drops_a_comment_whose_authoritative_reviewer_is_the_operator
    claimed = review_hash("state" => "commented", "user" => { "login" => "someone-else" })
    recorded = review_hash("state" => "commented")
    body = JSON.generate(review_payload("review" => claimed))

    pipeline(corroborating_runner(recorded)).process(body: body, signature: sign(body, @secret))

    assert_empty @output.string
    assert_match(/dropped review 7001: commented by the operator \(octocat\)/, @logs.string)
  end

  def test_emits_the_operators_own_comment_review_when_told_to_include_them
    review = review_hash("state" => "commented")
    body = JSON.generate(review_payload("review" => review))

    pipeline(corroborating_runner(review), include_self_reviews: true).process(body: body, signature: sign(body, @secret))

    emitted = JSON.parse(@output.string)
    assert_equal "commented", emitted["state"]
    assert_equal "octocat", emitted["reviewer"]
  end

  def test_emits_the_operators_own_requested_changes
    review = review_hash("state" => "changes_requested")
    body = JSON.generate(review_payload("review" => review))

    pipeline(corroborating_runner(review)).process(body: body, signature: sign(body, @secret))

    emitted = JSON.parse(@output.string)
    assert_equal "changes_requested", emitted["state"]
    assert_equal "octocat", emitted["reviewer"]
  end

  # Copilot reviews every push; its comment reviews are the loop's main input.
  def test_emits_copilots_comment_review
    review = review_hash("state" => "commented", "user" => { "login" => "Copilot" })
    body = JSON.generate(review_payload("review" => review))

    pipeline(corroborating_runner(review)).process(body: body, signature: sign(body, @secret))

    emitted = JSON.parse(@output.string)
    assert_equal "commented", emitted["state"]
    assert_equal "Copilot", emitted["reviewer"]
  end

  def test_emits_another_reviewers_comment
    review = review_hash("state" => "commented", "user" => { "login" => "someone-else" })
    body = JSON.generate(review_payload("review" => review))

    pipeline(corroborating_runner(review)).process(body: body, signature: sign(body, @secret))

    assert_equal "commented", JSON.parse(@output.string)["state"]
  end

  private
    # GitHub's REST API answers with the state upcased (`APPROVED`), unlike the
    # lowercase webhook delivery, so the corroboration stub takes the API's shape.
    def corroborating_runner(review = review_hash)
      runner = FakeCommandRunner.new
      runner.stub(%r{reviews/7001$}, stdout: JSON.generate(review.merge("state" => review["state"].upcase)))
      runner.stub "reviews/7001/comments", stdout: "[]"
      runner
    end

    def pipeline(runner, include_self_reviews: false)
      BasecampAgentConnector::GitHub::ReviewPipeline.new \
        secret: @secret,
        operator: "octocat",
        include_self_reviews: include_self_reviews,
        verifier: BasecampAgentConnector::GitHub::ReviewVerifier.new(github_cli: build_github_cli(runner)),
        emitter: BasecampAgentConnector::Emitter.new(output: @output),
        logger: @logs
    end
end
