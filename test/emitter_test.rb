require "test_helper"

class EmitterTest < Minitest::Test
  def test_emits_a_single_ndjson_line
    output = StringIO.new
    event = BasecampAgentConnector::Event.from_payload(sample_payload)

    BasecampAgentConnector::Emitter.new(output: output).emit(event)

    assert_equal 1, output.string.lines.length
    parsed = JSON.parse(output.string)
    assert_equal 99001, parsed["event_id"]
    assert_equal "comment_created", parsed["kind"]
    assert_equal({ "id" => 123, "name" => "Clawdito", "email_address" => "clawdito@example.com" }, parsed["creator"])
    assert_equal 456, parsed["recording"]["id"]
  end
end
