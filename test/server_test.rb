require "test_helper"
require "net/http"

class ServerTest < Minitest::Test
  def setup
    @port = free_port
    @hook = []
    @gh = []
    @status = nil
    @server = BasecampAgentConnector::Server.new(port: @port, logger: StringIO.new, routes: {
      "/hook/s3cret" => ->(request) { @hook << request; @status },
      "/gh/ghs3cret" => ->(request) { @gh << request; nil }
    })
    @thread = Thread.new { @server.start }
    wait_until_listening(@port)
  end

  def teardown
    @server.stop
    @thread.join(2)
  end

  def test_routes_each_path_to_its_own_handler
    post("/hook/s3cret", '{"from":"basecamp"}')
    post("/gh/ghs3cret", '{"from":"github"}')

    assert_equal [ '{"from":"basecamp"}' ], @hook.map(&:body)
    assert_equal [ '{"from":"github"}' ], @gh.map(&:body)
  end

  def test_exposes_request_headers_case_insensitively
    post("/gh/ghs3cret", "{}", "X-Hub-Signature-256" => "sha256=abc")

    assert_equal "sha256=abc", @gh.first.header("X-Hub-Signature-256")
  end

  def test_answers_200_when_the_handler_returns_no_status
    assert_equal "200", post("/hook/s3cret", "{}").code
    assert_equal "200", post("/gh/ghs3cret", "{}").code
  end

  def test_answers_the_status_the_handler_returns
    @status = 503

    assert_equal "503", post("/hook/s3cret", "{}").code
    assert_equal 1, @hook.length
  end

  def test_returns_404_for_unknown_paths
    response = post("/hook/wrong", "{}")

    assert_equal "404", response.code
    assert_empty @hook
    assert_empty @gh
  end

  private
    def post(path, body, headers = {})
      Net::HTTP.start("127.0.0.1", @port) do |http|
        http.post(path, body, { "Content-Type" => "application/json" }.merge(headers))
      end
    end
end
