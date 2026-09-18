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

  # The webhook delivers `state` lowercase; the REST API returns it uppercase.
  def test_reads_the_api_uppercase_state_as_the_documented_lowercase_form
    event = BasecampAgentConnector::GitHub::ReviewEvent.from_payload(review_payload("review" => review_hash("state" => "APPROVED")))

    assert_equal "approved", event.review_state
    assert event.actionable_state?
    assert event.approved?
    assert_equal "approved", event.to_emitted_hash["state"]
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

  def test_reviewed_by_matches_the_login_case_insensitively
    event = BasecampAgentConnector::GitHub::ReviewEvent.from_payload(review_payload("review" => review_hash("user" => { "login" => "OctoCat" })))

    assert event.reviewed_by?("octocat")
    refute event.reviewed_by?("someone-else")
    refute event.reviewed_by?(nil)
  end

  def test_reviewed_by_is_false_without_a_reviewer
    event = BasecampAgentConnector::GitHub::ReviewEvent.from_payload(review_payload("review" => review_hash("user" => nil)))

    refute event.reviewed_by?("octocat")
  end

  def test_reads_the_pull_request_author
    assert_equal "octocat", BasecampAgentConnector::GitHub::ReviewEvent.from_payload(review_payload).pull_author
  end

  def test_authored_by_matches_the_login_case_insensitively
    event = BasecampAgentConnector::GitHub::ReviewEvent.from_payload(
      review_payload("pull_request" => pull_request_hash("user" => { "login" => "OctoCat" })))

    assert event.authored_by?("octocat")
    refute event.authored_by?("someone-else")
    refute event.authored_by?(nil)
  end

  # Neither the operator's nor anyone else's: the gate reading this decides
  # what an unknown author means, and it lets the review through.
  def test_authored_by_is_false_without_an_author
    event = BasecampAgentConnector::GitHub::ReviewEvent.from_payload(
      review_payload("pull_request" => pull_request_hash("user" => nil)))

    assert_nil event.pull_author
    refute event.authored_by?("octocat")
  end

  # The marker, not the account, is what makes a review the agent's: agents
  # post under the operator's own login.
  def test_agent_authored_needs_every_written_line_marked
    assert agent_authored?(body: "🤖 addressed in 3f2a1c9")
    assert agent_authored?(body: "", comments: [ { "body" => "🤖 renamed" } ])
    assert agent_authored?(body: "🤖 one", comments: [ { "body" => "🤖 two" } ])

    refute agent_authored?(body: "this naming still reads backwards")
    refute agent_authored?(body: "🤖 addressed", comments: [ { "body" => "why not extract this?" } ])
    refute agent_authored?(body: "look at 🤖 in the middle")
    assert agent_authored?(body: "\n  🤖 marked past the leading whitespace")
  end

  def test_a_review_with_nothing_written_is_nobodys_word
    refute agent_authored?(body: nil)
    refute agent_authored?(body: "   ")
  end

  def test_emitted_hash_carries_review_and_comments
    payload = review_payload("comments" => [ { "path" => "lib/x.rb", "line" => 3, "body" => "rename this" } ])

    emitted = BasecampAgentConnector::GitHub::ReviewEvent.from_payload(payload).to_emitted_hash

    assert_equal "acme/widgets", emitted["repo"]
    assert_equal 12, emitted["pull_number"]
    assert_equal "changes_requested", emitted["state"]
    assert_equal 1, emitted["comments"].length
  end

  private
    def agent_authored?(body:, comments: [])
      payload = review_payload("review" => review_hash("state" => "commented", "body" => body), "comments" => comments)
      BasecampAgentConnector::GitHub::ReviewEvent.from_payload(payload).agent_authored?
    end
end
