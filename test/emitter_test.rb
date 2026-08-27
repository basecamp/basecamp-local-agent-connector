require "test_helper"

class EmitterTest < Minitest::Test
  def test_emits_a_single_ndjson_line
    output = StringIO.new
    event = BasecampAgentConnector::Basecamp::Event.from_payload(sample_payload)

    BasecampAgentConnector::Emitter.new(output: output).emit(event)

    assert_equal 1, output.string.lines.length
    parsed = JSON.parse(output.string)
    assert_equal 99001, parsed["event_id"]
    assert_equal "comment_created", parsed["kind"]
    assert_equal({ "id" => 100, "name" => "Operator", "email_address" => "operator@example.com" }, parsed["creator"])
    assert_equal 456, parsed["recording"]["id"]
  end

  def test_concurrent_emits_never_tear_a_line
    output = StringIO.new
    emitter = BasecampAgentConnector::Emitter.new(output: output)

    threads = 8.times.map do |thread_number|
      Thread.new do
        25.times do |emission|
          emitter.emit BasecampAgentConnector::Basecamp::Event.from_payload(sample_payload("id" => thread_number * 1000 + emission))
        end
      end
    end
    threads.each(&:join)

    lines = output.string.lines
    assert_equal 200, lines.length
    assert(lines.all? { |line| JSON.parse(line)["event_id"].is_a?(Integer) })
  end
end
