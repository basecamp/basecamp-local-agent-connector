require "test_helper"

class ChannelDispatchTest < Minitest::Test
  def test_maps_the_dispatch_payload_onto_the_shared_emitted_shape
    dispatch = BasecampAgentConnector::Channel::Dispatch.from_payload(payload)
    emitted = dispatch.to_emitted_hash

    assert_equal 55, emitted["dispatch_id"]
    assert_equal "mentioned", emitted["reason"]
    assert_equal 99001, emitted["event_id"]
    assert_equal "comment_created", emitted["kind"]
    assert_equal({ "id" => 100, "name" => "Jorge", "email_address" => "jorge@example.com" }, emitted["creator"])
    assert_equal 456, emitted["recording"]["id"]
    assert_equal "Comment", emitted["recording"]["type"]
  end

  def test_recording_is_reduced_to_the_pointer_fields
    emitted = BasecampAgentConnector::Channel::Dispatch.from_payload(payload).to_emitted_hash

    assert_equal %w[ id type app_url url content parent bucket ].sort,
      (emitted["recording"].keys & BasecampAgentConnector::Channel::Dispatch::EMITTED_RECORDING_FIELDS).sort
    refute emitted["recording"].key?("secret_field")
  end

  private
    def payload
      {
        "id" => 55,
        "reason" => "mentioned",
        "event" => {
          "id" => 99001,
          "kind" => "comment_created",
          "created_at" => "2026-07-14T12:00:00Z",
          "details" => {},
          "recording" => {
            "id" => 456, "type" => "Comment", "app_url" => "https://example.com/a",
            "url" => "https://example.com/a.json", "content" => "<p>hi</p>",
            "parent" => { "id" => 789 }, "bucket" => { "id" => 222 },
            "secret_field" => "nope"
          },
          "creator" => { "id" => 100, "name" => "Jorge", "email_address" => "jorge@example.com", "admin" => true }
        }
      }
    end
end
