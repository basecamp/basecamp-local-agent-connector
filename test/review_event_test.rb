require "test_helper"

class ReviewEventTest < Minitest::Test
  def test_reads_review_and_pull_request_fields
    event = BasecampAgentConnector::GitHub::ReviewEvent.from_payload(review_payload)

    assert_equal 7001, event.review_id
    assert_equal "changes_requested", event.review_state
    assert_equal "octocat", event.reviewer
    assert_equal 12, event.pull_number
    assert_equal "acme/widgets", event.repo
  end

  def test_dedup_id_is_the_review_id
    assert_equal 7001, BasecampAgentConnector::GitHub::ReviewEvent.from_payload(review_payload).id
  end

  def test_submitted_review_with_an_actionable_state_is_actionable
    event = BasecampAgentConnector::GitHub::ReviewEvent.from_payload(review_payload)

    assert event.actionable_action?
    assert event.actionable_state?
  end

  def test_non_submitted_action_is_not_actionable
    event = BasecampAgentConnector::GitHub::ReviewEvent.from_payload(review_payload("action" => "dismissed"))

    refute event.actionable_action?
  end

  def test_unknown_state_is_not_actionable
    event = BasecampAgentConnector::GitHub::ReviewEvent.from_payload(review_payload("review" => review_hash("state" => "pending")))

    refute event.actionable_state?
  end

  def test_emitted_hash_carries_review_and_comments
    payload = review_payload("comments" => [ { "path" => "lib/x.rb", "line" => 3, "body" => "rename this" } ])

    emitted = BasecampAgentConnector::GitHub::ReviewEvent.from_payload(payload).to_emitted_hash

    assert_equal "acme/widgets", emitted["repo"]
    assert_equal 12, emitted["pull_number"]
    assert_equal "changes_requested", emitted["state"]
    assert_equal 1, emitted["comments"].length
  end
end
