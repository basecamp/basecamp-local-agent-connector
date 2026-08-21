require "test_helper"

class TunnelTest < Minitest::Test
  def test_start_mounts_each_path_with_a_path_carrying_proxy_target
    runner = FakeCommandRunner.new
    runner.stub "tailscale funnel", exit_status: 0
    runner.stub "tailscale status --json", stdout: JSON.generate("Self" => { "DNSName" => "desktop.example.ts.net." })

    url = BasecampAgentConnector::Tunnel.new(port: 4567, paths: [ "/bc5/abc", "/gh/def" ], command_runner: runner).start

    assert_equal "https://desktop.example.ts.net", url
    assert_equal [
      [ "tailscale", "funnel", "--bg", "--set-path", "/bc5/abc", "http://127.0.0.1:4567/bc5/abc" ],
      [ "tailscale", "funnel", "--bg", "--set-path", "/gh/def", "http://127.0.0.1:4567/gh/def" ]
    ], runner.commands_matching(/funnel/)
  end

  def test_start_raises_when_funnel_fails
    runner = FakeCommandRunner.new
    runner.stub "tailscale funnel", exit_status: 1, stderr: "Funnel is not enabled"

    assert_raises BasecampAgentConnector::Tunnel::Error do
      BasecampAgentConnector::Tunnel.new(port: 4567, paths: [ "/bc5/abc" ], command_runner: runner).start
    end
  end

  def test_stop_unmounts_each_path_and_never_resets_the_funnel
    runner = FakeCommandRunner.new
    runner.stub "tailscale funnel", exit_status: 0

    BasecampAgentConnector::Tunnel.new(port: 4567, paths: [ "/bc5/abc", "/gh/def" ], command_runner: runner).stop

    assert_equal [
      [ "tailscale", "funnel", "--set-path", "/bc5/abc", "off" ],
      [ "tailscale", "funnel", "--set-path", "/gh/def", "off" ]
    ], runner.commands_matching(/funnel/)
    assert_empty runner.commands_matching(/reset/)
  end
end
