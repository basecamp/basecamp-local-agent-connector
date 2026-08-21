require "test_helper"

class EventTest < Minitest::Test
  def test_actionable_kind
    assert from_kind("comment_created").actionable_kind?
    assert from_kind("message_content_changed").actionable_kind?
    assert from_kind("kanban_card_assignment_changed").actionable_kind?
    assert from_kind("todo_assignment_changed").actionable_kind?
    refute from_kind("comment_archived").actionable_kind?
    refute from_kind(nil).actionable_kind?
  end

  def test_assigns_the_agent
    agent = agent_identity(person_id: 200)

    assert BasecampAgentConnector::Basecamp::Event.from_payload(assignment_payload).assigns?(agent)
    refute BasecampAgentConnector::Basecamp::Event.from_payload(assignment_payload("details" => { "added_person_ids" => [ 999 ] })).assigns?(agent)
    # an assignment removing the agent is not a trigger
    refute BasecampAgentConnector::Basecamp::Event.from_payload(assignment_payload("details" => { "added_person_ids" => [], "removed_person_ids" => [ 200 ] })).assigns?(agent)
    # a non-assignment kind never "assigns", even if details somehow carry the id
    refute BasecampAgentConnector::Basecamp::Event.from_payload(sample_payload("details" => { "added_person_ids" => [ 200 ] })).assigns?(agent)
    refute BasecampAgentConnector::Basecamp::Event.from_payload(assignment_payload).assigns?(agent_identity(person_id: nil))
  end

  def test_to_emitted_hash_carries_assignment_details
    emitted = BasecampAgentConnector::Basecamp::Event.from_payload(assignment_payload).to_emitted_hash

    assert_equal [ 200 ], emitted["details"]["added_person_ids"]
  end

  def test_authored_by_matches_on_the_account_person_id
    operator = BasecampAgentConnector::Basecamp::Identity.new(id: 100, email: "operator@example.com", person_id: 35753702)

    assert BasecampAgentConnector::Basecamp::Event.from_payload(sample_payload("creator" => { "id" => 35753702 })).authored_by?(operator)
    refute BasecampAgentConnector::Basecamp::Event.from_payload(sample_payload("creator" => { "id" => 999 })).authored_by?(operator)
  end

  # Basecamp masks other people's addresses on a recording read, so the only
  # unmasked thing the operator check can stand on is the id. Matching on email
  # here answers false and every mention and assignment silently stops firing.
  def test_a_masked_email_does_not_stop_the_operator_check
    operator = BasecampAgentConnector::Basecamp::Identity.new(id: 100, email: "folivares@basecamp.com", person_id: 35753702)
    masked = sample_payload("creator" => { "id" => 35753702, "email_address" => "f\u2022\u2022\u2022\u2022\u2022\u2022\u2022\u2022@\u2022\u2022\u2022\u2022\u2022\u2022\u2022\u2022.\u2022\u2022\u2022" })

    assert BasecampAgentConnector::Basecamp::Event.from_payload(masked).authored_by?(operator)
  end

  # A masked address must never be read as a match on its own.
  def test_a_masked_email_alone_is_not_the_operator
    operator = BasecampAgentConnector::Basecamp::Identity.new(id: 100, email: "folivares@basecamp.com")
    masked = sample_payload("creator" => { "email_address" => "f\u2022\u2022\u2022\u2022\u2022\u2022\u2022\u2022@\u2022\u2022\u2022\u2022\u2022\u2022\u2022\u2022.\u2022\u2022\u2022" })

    refute BasecampAgentConnector::Basecamp::Event.from_payload(masked).authored_by?(operator)
  end

  # The id wins when both are present and they disagree, so a shared or stale
  # address cannot authorize somebody else's event.
  def test_the_person_id_decides_when_it_disagrees_with_the_email
    operator = BasecampAgentConnector::Basecamp::Identity.new(id: 100, email: "operator@example.com", person_id: 35753702)

    refute BasecampAgentConnector::Basecamp::Event.from_payload(sample_payload("creator" => { "id" => 999, "email_address" => "operator@example.com" })).authored_by?(operator)
    assert BasecampAgentConnector::Basecamp::Event.from_payload(sample_payload("creator" => { "id" => 35753702, "email_address" => "someone@example.com" })).authored_by?(operator)
  end

  def test_authored_by_matches_on_email
    assert BasecampAgentConnector::Basecamp::Event.from_payload(sample_payload).authored_by?(operator_identity)
    assert BasecampAgentConnector::Basecamp::Event.from_payload(sample_payload("creator" => { "email_address" => "OPERATOR@example.com" })).authored_by?(operator_identity)
    refute BasecampAgentConnector::Basecamp::Event.from_payload(sample_payload("creator" => { "email_address" => "someone@example.com" })).authored_by?(operator_identity)
    refute BasecampAgentConnector::Basecamp::Event.from_payload(sample_payload("creator" => {})).authored_by?(operator_identity)
  end

  def test_mentions_the_agent
    agent = agent_identity(person_id: 200)

    assert with_content("<p>Hey #{mention_html(person_id: 200)} please</p>").mentions?(agent)
    assert with_content("<p>#{mention_html(person_id: 111)} and #{mention_html(person_id: 200)}</p>").mentions?(agent)
    refute with_content("<p>Hey #{mention_html(person_id: 999)} please</p>").mentions?(agent)
    refute with_content("<p>plain text naming the agent without a mention attachment</p>").mentions?(agent)
    refute with_content(nil).mentions?(agent)
    refute with_content("<p>#{mention_html(person_id: 200)}</p>").mentions?(agent_identity(person_id: nil))
  end

  def test_mentions_the_agent_in_a_real_webhook_payload
    agent = agent_identity(person_id: 200)

    assert with_content("<p>are you listening #{webhook_mention_html(person_id: 200)} ?</p>").mentions?(agent)
    refute with_content("<p>are you listening #{webhook_mention_html(person_id: 999)} ?</p>").mentions?(agent)
  end

  def test_to_emitted_hash_keeps_only_known_fields
    recording = sample_recording("status" => "active", "bookmark_url" => "https://example.org/b")
    event = BasecampAgentConnector::Basecamp::Event.from_payload(sample_payload("recording" => recording))
    emitted = event.to_emitted_hash

    refute emitted["recording"].key?("status")
    refute emitted["recording"].key?("bookmark_url")
    assert_equal %w[email_address id name], emitted["creator"].keys.sort
    assert_equal 99001, emitted["event_id"]
  end

  private
    def from_kind(kind)
      BasecampAgentConnector::Basecamp::Event.from_payload("kind" => kind)
    end

    def with_content(content)
      BasecampAgentConnector::Basecamp::Event.from_payload("recording" => { "content" => content })
    end
end
