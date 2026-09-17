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

  # A dispatched agent posts under the operator's own GitHub account, so the
  # account cannot tell its replies from the operator's own review comments.
  # The 🤖 prefix our convention puts on every agent-written PR comment can.
  def test_drops_the_operators_comment_review_whose_every_line_is_agent_marked
    review = review_hash("state" => "commented", "body" => "🤖 addressed in 3f2a1c9")
    body = JSON.generate(review_payload("review" => review))

    pipeline(corroborating_runner(review)).process(body: body, signature: sign(body, @secret))

    assert_empty @output.string
    assert_match(/dropped review 7001: commented by the operator \(octocat\), body and every inline comment 🤖-marked/, @logs.string)
  end

  def test_drops_the_operators_comment_review_whose_inline_comments_are_all_agent_marked
    review = review_hash("state" => "commented", "body" => "")
    runner = corroborating_runner(review, comments: [ { "path" => "lib/x.rb", "body" => "🤖 renamed" }, { "path" => "lib/y.rb", "body" => "🤖 done" } ])
    body = JSON.generate(review_payload("review" => review))

    pipeline(runner).process(body: body, signature: sign(body, @secret))

    assert_empty @output.string
    assert_match(/body and every inline comment 🤖-marked/, @logs.string)
  end

  # A review with nothing written in it is nobody's word, so it travels.
  def test_emits_the_operators_empty_comment_review
    review = review_hash("state" => "commented", "body" => "")
    body = JSON.generate(review_payload("review" => review))

    pipeline(corroborating_runner(review)).process(body: body, signature: sign(body, @secret))

    assert_equal 7001, JSON.parse(@output.string)["review_id"]
  end

  # The one this must never get wrong: the operator reviewing their own PR by
  # hand. Losing a person's review comment is far worse than the noise dropped
  # above.
  def test_emits_the_operators_own_hand_written_comment_review
    review = review_hash("state" => "commented", "body" => "this naming still reads backwards")
    body = JSON.generate(review_payload("review" => review))

    pipeline(corroborating_runner(review)).process(body: body, signature: sign(body, @secret))

    emitted = JSON.parse(@output.string)
    assert_equal "commented", emitted["state"]
    assert_equal "octocat", emitted["reviewer"]
  end

  # One agent reply and one human comment in the same review: the review
  # travels whole, agent line included.
  def test_emits_a_mixed_review_carrying_one_unmarked_comment
    review = review_hash("state" => "commented", "body" => "🤖 addressed in 3f2a1c9")
    runner = corroborating_runner(review, comments: [ { "path" => "lib/x.rb", "body" => "🤖 renamed" }, { "path" => "lib/y.rb", "body" => "why not extract this?" } ])
    body = JSON.generate(review_payload("review" => review))

    pipeline(runner).process(body: body, signature: sign(body, @secret))

    emitted = JSON.parse(@output.string)
    assert_equal "commented", emitted["state"]
    assert_equal 2, emitted["comments"].length
    assert_empty @logs.string
  end

  # The marked text is what identifies the agent, so a marked review by anyone
  # else is still theirs.
  def test_emits_another_reviewers_agent_marked_comment_review
    review = review_hash("state" => "commented", "body" => "🤖 a bot of their own", "user" => { "login" => "someone-else" })
    body = JSON.generate(review_payload("review" => review))

    pipeline(corroborating_runner(review)).process(body: body, signature: sign(body, @secret))

    assert_equal "someone-else", JSON.parse(@output.string)["reviewer"]
  end

  # An approval is the trust signal the whole loop rests on: it lands PRs, so
  # it passes however it is written.
  def test_emits_the_operators_agent_marked_approval
    approval = review_hash("state" => "approved", "body" => "🤖 green on the final head")
    body = JSON.generate(review_payload("review" => approval))

    pipeline(corroborating_runner(approval)).process(body: body, signature: sign(body, @secret))

    assert_equal "approved", JSON.parse(@output.string)["state"]
  end

  # Work to do is work to do, whoever marked it.
  def test_emits_the_operators_agent_marked_requested_changes
    review = review_hash("state" => "changes_requested", "body" => "🤖 the migration is missing")
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

  # A body reading like the agent's is not enough on its own: if GitHub would
  # not hand over the inline comments, one of them may be a person's, so the
  # review travels.
  def test_emits_an_agent_marked_review_whose_inline_comments_could_not_be_read
    review = review_hash("state" => "commented", "body" => "🤖 addressed in 3f2a1c9")
    runner = FakeCommandRunner.new
    runner.stub(%r{reviews/7001$}, stdout: JSON.generate(review.merge("state" => "COMMENTED")))
    runner.stub "reviews/7001/comments", exit_status: 1, stderr: "502 Bad Gateway"
    body = JSON.generate(review_payload("review" => review))

    pipeline(runner).process(body: body, signature: sign(body, @secret))

    assert_equal 7001, JSON.parse(@output.string)["review_id"]
  end

  # The delivery carries the body but none of the inline comments, and one
  # unmarked comment is a person writing — so this drop waits for the review
  # the API hands back whole, unlike the approval gate above.
  def test_asks_github_for_the_inline_comments_before_dropping_an_agent_marked_body
    review = review_hash("state" => "commented", "body" => "🤖 addressed in 3f2a1c9")
    runner = corroborating_runner(review, comments: [ { "path" => "lib/y.rb", "body" => "why not extract this?" } ])
    body = JSON.generate(review_payload("review" => review))

    pipeline(runner).process(body: body, signature: sign(body, @secret))

    assert_equal 1, @output.string.lines.length
    refute_empty runner.commands_matching(%r{reviews/7001/comments})
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
    def corroborating_runner(review = review_hash, comments: [])
      runner = FakeCommandRunner.new
      runner.stub(%r{reviews/7001$}, stdout: JSON.generate(review.merge("state" => review["state"].upcase)))
      runner.stub "reviews/7001/comments", stdout: JSON.generate(comments)
      runner
    end

    def pipeline(runner)
      BasecampAgentConnector::GitHub::ReviewPipeline.new \
        secret: @secret,
        operator: "octocat",
        verifier: BasecampAgentConnector::GitHub::ReviewVerifier.new(github_cli: build_github_cli(runner)),
        emitter: BasecampAgentConnector::Emitter.new(output: @output),
        logger: @logs
    end
end
