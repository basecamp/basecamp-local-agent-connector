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

  def test_chat_line_payload_synthesizes_a_chat_kind_event
    event = BasecampAgentConnector::Basecamp::Event.from_payload(chat_line_payload)

    assert event.chat_kind?
    assert event.actionable_kind?
    assert_equal "chat_lines_rich_text_created", event.kind
    assert_equal 91001, event.id
    assert_equal 100, event.creator_id
    assert event.mentions?(agent_identity(person_id: 200))
    refute event.assignment_changed?
  end

  def test_chat_line_kind_mirrors_bc3_kind_derivation
    assert_equal "chat_lines_text_created", BasecampAgentConnector::Basecamp::Event.chat_line_kind("Chat::Lines::Text")
    assert_equal "chat_lines_rich_text_created", BasecampAgentConnector::Basecamp::Event.chat_line_kind("Chat::Lines::RichText")
  end

  def test_non_chat_kinds_are_not_chat_kind
    refute from_kind("comment_created").chat_kind?
    refute from_kind("kanban_card_assignment_changed").chat_kind?
  end

  private
    def from_kind(kind)
      BasecampAgentConnector::Basecamp::Event.from_payload("kind" => kind)
    end

    def with_content(content)
      BasecampAgentConnector::Basecamp::Event.from_payload("recording" => { "content" => content })
    end
end
