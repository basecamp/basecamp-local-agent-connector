require "test_helper"

class TunnelTest < Minitest::Test
  def test_start_returns_the_public_url
    runner = FakeCommandRunner.new
    runner.stub "tailscale funnel --bg", exit_status: 0
    runner.stub "tailscale status --json", stdout: JSON.generate("Self" => { "DNSName" => "desktop.example.ts.net." })

    url = BasecampAgentConnector::Tunnel.new(port: 4567, command_runner: runner).start

    assert_equal "https://desktop.example.ts.net", url
  end

  def test_start_raises_when_funnel_fails
    runner = FakeCommandRunner.new
    runner.stub "tailscale funnel", exit_status: 1, stderr: "Funnel is not enabled"

    assert_raises BasecampAgentConnector::Tunnel::Error do
      BasecampAgentConnector::Tunnel.new(port: 4567, command_runner: runner).start
    end
  end

  def test_stop_resets_the_funnel
    runner = FakeCommandRunner.new
    runner.stub "tailscale funnel reset", exit_status: 0

    BasecampAgentConnector::Tunnel.new(port: 4567, command_runner: runner).stop

    assert_equal 1, runner.commands_matching(/funnel reset/).length
  end
end
