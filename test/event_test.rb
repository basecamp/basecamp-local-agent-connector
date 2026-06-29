require "test_helper"

class EventTest < Minitest::Test
  def test_actionable_kind
    assert from_kind("comment_created").actionable_kind?
    assert from_kind("message_content_changed").actionable_kind?
    refute from_kind("comment_archived").actionable_kind?
    refute from_kind(nil).actionable_kind?
  end

  def test_authored_by_matches_on_email
    assert BasecampAgentConnector::Event.from_payload(sample_payload).authored_by?(operator_identity)
    assert BasecampAgentConnector::Event.from_payload(sample_payload("creator" => { "email_address" => "OPERATOR@example.com" })).authored_by?(operator_identity)
    refute BasecampAgentConnector::Event.from_payload(sample_payload("creator" => { "email_address" => "someone@example.com" })).authored_by?(operator_identity)
    refute BasecampAgentConnector::Event.from_payload(sample_payload("creator" => {})).authored_by?(operator_identity)
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
    event = BasecampAgentConnector::Event.from_payload(sample_payload("recording" => recording))
    emitted = event.to_emitted_hash

    refute emitted["recording"].key?("status")
    refute emitted["recording"].key?("bookmark_url")
    assert_equal %w[email_address id name], emitted["creator"].keys.sort
    assert_equal 99001, emitted["event_id"]
  end

  private
    def from_kind(kind)
      BasecampAgentConnector::Event.from_payload("kind" => kind)
    end

    def with_content(content)
      BasecampAgentConnector::Event.from_payload("recording" => { "content" => content })
    end
end
