require "test_helper"
require "net/http"

class ServerTest < Minitest::Test
  def setup
    @port = free_port
    @received = []
    @server = BasecampAgentConnector::Server.new(port: @port, secret: "s3cret", handler: ->(payload) { @received << payload }, logger: StringIO.new)
    @thread = Thread.new { @server.start }
    wait_until_listening(@port)
  end

  def teardown
    @server.stop
    @thread.join(2)
  end

  def test_accepts_post_to_the_secret_path
    response = post("/hook/s3cret", '{"hello":"world"}')

    assert_equal "200", response.code
    assert_equal [ { "hello" => "world" } ], @received
  end

  def test_returns_404_for_other_paths
    response = post("/hook/wrong", "{}")

    assert_equal "404", response.code
    assert_empty @received
  end

  private
    def post(path, body)
      Net::HTTP.start("127.0.0.1", @port) do |http|
        http.post(path, body, "Content-Type" => "application/json")
      end
    end
end
