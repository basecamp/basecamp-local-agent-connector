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

  def test_remount_missing_remounts_only_the_paths_the_funnel_lost
    runner = FakeCommandRunner.new
    runner.stub "funnel status --json", stdout: funnel_status("/bc5/abc", "/someone/elses")
    runner.stub "--set-path", exit_status: 0

    remounted = tunnel(runner, paths: [ "/bc5/abc", "/gh/def" ]).remount_missing

    assert_equal [ "/gh/def" ], remounted
    assert_equal [ [ "tailscale", "funnel", "--bg", "--set-path", "/gh/def", "http://127.0.0.1:4567/gh/def" ] ],
      runner.commands_matching(/set-path/)
  end

  def test_remount_missing_leaves_a_healthy_funnel_alone
    runner = FakeCommandRunner.new
    runner.stub "funnel status --json", stdout: funnel_status("/bc5/abc")

    assert_empty tunnel(runner, paths: [ "/bc5/abc" ]).remount_missing
    assert_empty runner.commands_matching(/set-path/)
  end

  # A status that isn't the JSON document (no serve config at all, say) can't
  # prove anything is mounted, and remounting a mounted path is harmless.
  # `tailscale funnel reset` leaves nothing; `tailscale serve` keeps the
  # handler but takes it off the internet. Both are outages here.
  def test_remount_missing_treats_a_path_served_without_funnel_as_lost
    runner = FakeCommandRunner.new
    runner.stub "funnel status --json", stdout: funnel_status("/bc5/abc", allow_funnel: false)
    runner.stub "--set-path", exit_status: 0

    assert_equal [ "/bc5/abc" ], tunnel(runner, paths: [ "/bc5/abc" ]).remount_missing
  end

  def test_remount_missing_reads_an_unparseable_status_as_nothing_mounted
    runner = FakeCommandRunner.new
    runner.stub "funnel status --json", stdout: "No serve config\n"
    runner.stub "--set-path", exit_status: 0

    assert_equal [ "/bc5/abc" ], tunnel(runner, paths: [ "/bc5/abc" ]).remount_missing
  end

  def test_remount_missing_raises_when_status_cannot_be_read
    runner = FakeCommandRunner.new
    runner.stub "funnel status --json", exit_status: 1, stderr: "tailscaled is not running"

    assert_raises BasecampAgentConnector::Tunnel::Error do
      tunnel(runner, paths: [ "/bc5/abc" ]).remount_missing
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

  private
    def tunnel(runner, paths:)
      BasecampAgentConnector::Tunnel.new(port: 4567, paths: paths, command_runner: runner)
    end

    # `tailscale funnel status --json`: handlers keyed by mount path under
    # each served host:port (verified against a live funnel).
    def funnel_status(*paths, allow_funnel: true)
      handlers = paths.to_h { |path| [ path, { "Proxy" => "http://127.0.0.1:4567#{path}" } ] }
      JSON.generate("Web" => { "host.example.ts.net:443" => { "Handlers" => handlers } },
        "AllowFunnel" => { "host.example.ts.net:443" => allow_funnel })
    end
end
