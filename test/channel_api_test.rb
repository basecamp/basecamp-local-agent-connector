require "test_helper"

class ChannelApiTest < Minitest::Test
  def test_fetches_dispatches_after_a_cursor_with_the_connection_token
    http = FakeHttp.new(body: JSON.generate([ { "id" => 7, "reason" => "mentioned", "event" => { "id" => 7 } } ]))
    api = build_api(http)

    dispatches = api.dispatches(after: 3)

    assert_equal [ 7 ], dispatches.map(&:id)
    assert_includes http.last_request.path, "/my/agent/dispatches"
    assert_includes http.last_request["Authorization"], "Agent-Connection token-123"
  end

  def test_acking_puts_to_the_dispatch
    http = FakeHttp.new(body: "")
    build_api(http).ack(7)

    assert_equal "PUT", http.last_request.method
    assert_includes http.last_request.path, "/my/agent/dispatches/7"
  end

  def test_raises_on_a_non_success_response
    http = FakeHttp.new(status: "401")
    error = assert_raises(BasecampAgentConnector::Channel::Api::Error) do
      build_api(http).dispatches(after: 0)
    end
    assert_includes error.message, "401"
  end

  private
    def build_api(http)
      BasecampAgentConnector::Channel::Api.new \
        base_url: "https://example.com/12345", connection_token: "token-123", http: http
    end

    class FakeHttp
      attr_reader :last_request

      def initialize(body: "", status: "200")
        @body = body
        @status = status
      end

      def start(_host, _port, use_ssl:)
        yield self
      end

      def request(message)
        @last_request = message
        FakeResponse.new(@body, @status)
      end
    end

    class FakeResponse
      def initialize(body, status)
        @body = body
        @status = status
      end

      attr_reader :body

      def code = @status
      def is_a?(klass) = klass == Net::HTTPSuccess ? @status.start_with?("2") : super
    end
end
