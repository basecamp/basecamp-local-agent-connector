require "test_helper"

class EmitterTest < Minitest::Test
  def test_emits_a_single_ndjson_line
    output = StringIO.new
    dispatch = BasecampAgentConnector::Channel::Dispatch.from_payload(sample_dispatch)

    BasecampAgentConnector::Emitter.new(output: output).emit(dispatch)

    assert_equal 1, output.string.lines.length
    parsed = JSON.parse(output.string)
    assert_equal 55, parsed["dispatch_id"]
    assert_equal "mentioned", parsed["reason"]
    assert_equal 99001, parsed["event_id"]
    assert_equal "comment_created", parsed["kind"]
    assert_equal({ "id" => 100, "name" => "Operator", "email_address" => "operator@example.com" }, parsed["creator"])
    assert_equal 456, parsed["recording"]["id"]
  end

  private
    def sample_dispatch
      {
        "id" => 55,
        "reason" => "mentioned",
        "event" => {
          "id" => 99001,
          "kind" => "comment_created",
          "created_at" => "2026-07-14T12:00:00Z",
          "details" => {},
          "recording" => { "id" => 456, "type" => "Comment", "bucket" => { "id" => 222 } },
          "creator" => { "id" => 100, "name" => "Operator", "email_address" => "operator@example.com" }
        }
      }
    end
end
