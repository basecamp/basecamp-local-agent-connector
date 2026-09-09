require "test_helper"

class DeviceFlowTest < Minitest::Test
  def setup
    @calls = []
    @answers = []
    @sleeps = []
    @now = Time.utc(2026, 9, 9, 1, 0, 0)
  end

  def test_proves_control_of_the_declared_login_and_keeps_no_token
    answer "device_code" => "dc", "user_code" => "ABCD-1234", "verification_uri" => "https://github.com/login/device", "expires_in" => 900, "interval" => 5
    answer "error" => "authorization_pending"
    answer "error" => "slow_down"
    answer "access_token" => "gho_once", "token_type" => "bearer"
    answer "login" => "marie", "id" => 4242

    flow = flow()
    code = flow.start
    identity = flow.wait(code)

    assert_equal "ABCD-1234", code.user_code
    assert_equal BasecampAgentConnector::GitHub::DeviceFlow::Identity.new(login: "marie", id: 4242), identity
    assert_equal [ 5, 5, 10 ], @sleeps
    assert_equal "gho_once", @calls.last[:token]
    assert_equal "https://api.github.com/user", @calls.last[:url]
    assert_equal "Iv1.abc", @calls.first[:body]["client_id"]
  end

  def test_denial_expiry_and_timeout_fail_by_name
    answer "device_code" => "dc", "user_code" => "X", "verification_uri" => "u", "expires_in" => 900, "interval" => 1
    answer "error" => "access_denied"
    flow = flow()
    error = assert_raises(BasecampAgentConnector::GitHub::DeviceFlow::Failed) { flow.wait(flow.start) }
    assert_match(/declined/, error.message)

    @answers.clear
    answer "device_code" => "dc", "user_code" => "X", "verification_uri" => "u", "expires_in" => 900, "interval" => 1
    answer "error" => "expired_token"
    error = assert_raises(BasecampAgentConnector::GitHub::DeviceFlow::Failed) { flow.wait(flow.start) }
    assert_match(/expired/, error.message)

    @answers.clear
    answer "device_code" => "dc", "user_code" => "X", "verification_uri" => "u", "expires_in" => 2, "interval" => 1
    3.times { answer "error" => "authorization_pending" }
    flow = flow(advance: 1)
    error = assert_raises(BasecampAgentConnector::GitHub::DeviceFlow::Failed) { flow.wait(flow.start) }
    assert_match(/within/, error.message)
  end

  def test_polling_rides_through_a_transient_network_failure
    answer "device_code" => "dc", "user_code" => "X", "verification_uri" => "u", "expires_in" => 900, "interval" => 1
    answer BasecampAgentConnector::GitHub::DeviceFlow::Unreachable.new("could not reach github.com: timeout")
    answer "access_token" => "gho_once"
    answer "login" => "marie", "id" => 4242

    flow = flow()
    assert_equal "marie", flow.wait(flow.start).login
    assert_equal [ 1, 1 ], @sleeps
  end

  def test_a_flow_that_cannot_start_says_why
    answer "error" => "unauthorized_client", "error_description" => "device flow is not enabled"

    error = assert_raises(BasecampAgentConnector::GitHub::DeviceFlow::Failed) { flow.start }
    assert_match(/not enabled/, error.message)
  end

  # `bin/pair approve` relays every failure as an {"error"} line; a network
  # that is down has to arrive the same way, not as a stack trace.
  def test_an_unreachable_github_fails_by_name
    flow = BasecampAgentConnector::GitHub::DeviceFlow.new(client_id: "Iv1.abc")

    Net::HTTP.stub(:start, ->(*) { raise Errno::ECONNREFUSED }) do
      error = assert_raises(BasecampAgentConnector::GitHub::DeviceFlow::Failed) { flow.start }
      assert_match(/could not reach github.com/, error.message)
    end
  end

  def test_client_id_comes_from_the_host_config
    Dir.mktmpdir do |directory|
      path = File.join(directory, "github-oauth.json")
      assert_raises(BasecampAgentConnector::GitHub::DeviceFlow::Failed) { BasecampAgentConnector::GitHub::DeviceFlow.client_id(path) }
      File.write path, JSON.generate("client_id" => "Iv1.abc")
      assert_equal "Iv1.abc", BasecampAgentConnector::GitHub::DeviceFlow.client_id(path)
    end
  end

  private
    def answer(hash)
      @answers << hash
    end

    def flow(advance: 0)
      http = lambda do |url, body, token: nil|
        @calls << { url: url, body: body, token: token }
        answer = @answers.shift or raise "no more answers for #{url}"
        answer.is_a?(Exception) ? raise(answer) : answer
      end
      BasecampAgentConnector::GitHub::DeviceFlow.new(client_id: "Iv1.abc", http: http,
        clock: -> { @now += advance }, sleeper: ->(seconds) { @sleeps << seconds })
    end
end
