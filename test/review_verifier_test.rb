require "test_helper"

class ReviewVerifierTest < Minitest::Test
  def test_corroborates_and_attaches_inline_comments
    runner = FakeCommandRunner.new
    runner.stub(%r{reviews/7001$}, stdout: JSON.generate(review_hash("body" => "fetched body")))
    runner.stub "reviews/7001/comments", stdout: JSON.generate([ { "path" => "lib/x.rb", "line" => 3, "body" => "rename" } ])

    verified = verifier(runner).verify(event(review_payload))

    refute_nil verified
    assert_equal "fetched body", verified.review_body
    assert_equal 1, verified.comments.length
    assert verified.comments_complete?
  end

  # An empty list and an unanswered fetch look alike on the wire; only the
  # first is the list GitHub holds.
  def test_marks_the_comment_list_incomplete_when_github_would_not_answer
    runner = FakeCommandRunner.new
    runner.stub(%r{reviews/7001$}, stdout: JSON.generate(review_hash))
    runner.stub "reviews/7001/comments", exit_status: 1, stderr: "502 Bad Gateway"

    verified = verifier(runner).verify(event(review_payload))

    assert_empty verified.comments
    refute verified.comments_complete?
  end

  def test_marks_an_empty_comment_list_complete
    runner = FakeCommandRunner.new
    runner.stub(%r{reviews/7001$}, stdout: JSON.generate(review_hash))
    runner.stub "reviews/7001/comments", stdout: "[]"

    assert verifier(runner).verify(event(review_payload)).comments_complete?
  end

  def test_rejects_when_the_review_is_not_found
    runner = FakeCommandRunner.new
    runner.stub(%r{reviews/7001$}, exit_status: 1, stderr: "Not Found")

    assert_nil verifier(runner).verify(event(review_payload))
  end

  def test_does_not_call_github_without_a_locator
    runner = FakeCommandRunner.new
    payload = review_payload("pull_request" => {})

    assert_nil verifier(runner).verify(event(payload))
    assert_empty runner.commands
  end

  private
    def verifier(runner)
      BasecampAgentConnector::GitHub::ReviewVerifier.new(github_cli: build_github_cli(runner))
    end

    def event(payload)
      BasecampAgentConnector::GitHub::ReviewEvent.from_payload(payload)
    end
end
