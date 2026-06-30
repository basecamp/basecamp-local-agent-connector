require "test_helper"
require "net/http"

class ServerTest < Minitest::Test
  def setup
    @port = free_port
    @received = []
    @server = BasecampAgentConnector::Server.new(port: @port, path: "/hook/s3cret", handler: ->(request) { @received << request }, logger: StringIO.new)
    @thread = Thread.new { @server.start }
    wait_until_listening(@port)
  end

  def teardown
    @server.stop
    @thread.join(2)
  end

  def test_accepts_post_to_the_path_with_raw_body
    response = post("/hook/s3cret", '{"hello":"world"}')

    assert_equal "200", response.code
    assert_equal [ '{"hello":"world"}' ], @received.map(&:body)
  end

  def test_exposes_request_headers_case_insensitively
    post("/hook/s3cret", "{}", "X-Hub-Signature-256" => "sha256=abc")

    assert_equal "sha256=abc", @received.first.header("X-Hub-Signature-256")
  end

  def test_returns_404_for_other_paths
    response = post("/hook/wrong", "{}")

    assert_equal "404", response.code
    assert_empty @received
  end

  private
    def post(path, body, headers = {})
      Net::HTTP.start("127.0.0.1", @port) do |http|
        http.post(path, body, { "Content-Type" => "application/json" }.merge(headers))
      end
    end
end
