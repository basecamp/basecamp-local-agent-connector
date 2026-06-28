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
    agent = agent_identity(name: "Clawdito")

    assert with_content("<p>Hey #{mention_html('Clawdito')} please</p>").mentions?(agent)
    refute with_content("<p>Hey #{mention_html('Someone')} please</p>").mentions?(agent)
    refute with_content("<p>plain text saying Clawdito without a mention</p>").mentions?(agent)
    refute with_content(nil).mentions?(agent)
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
