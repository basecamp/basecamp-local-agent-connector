require "test_helper"

class FunnelMonitorTest < Minitest::Test
  def setup
    @logs = StringIO.new
  end

  def test_check_remounts_a_lost_path_and_says_so
    runner = FakeCommandRunner.new
    runner.stub "funnel status --json", stdout: "{}"
    runner.stub "--set-path", exit_status: 0

    monitor(runner).check

    assert_equal [ [ "tailscale", "funnel", "--bg", "--set-path", "/bc5/abc", "http://127.0.0.1:4567/bc5/abc" ] ],
      runner.commands_matching(/set-path/)
    assert_match(%r{funnel path /bc5/abc was no longer mounted.*remounted it}, @logs.string)
  end

  def test_check_is_quiet_when_the_funnel_is_healthy
    runner = FakeCommandRunner.new
    runner.stub "funnel status --json", stdout: funnel_status("/bc5/abc")

    monitor(runner).check

    assert_empty @logs.string
    assert_empty runner.commands_matching(/set-path/)
  end

  def test_start_checks_nothing_before_the_first_interval_and_stop_ends_the_thread
    runner = FakeCommandRunner.new
    runner.stub "funnel status --json", stdout: funnel_status("/bc5/abc")
    ticks = Queue.new
    monitor = monitor(runner, wait: ->(_seconds) { ticks.pop })

    monitor.start
    assert_empty runner.commands

    2.times { ticks << true }
    deadline = Time.now + 2
    sleep 0.01 while runner.commands_matching(/funnel status/).empty? && Time.now < deadline
    refute_empty runner.commands_matching(/funnel status/)

    monitor.stop
    refute monitor.instance_variable_get(:@thread)
  end

  def test_the_check_thread_survives_a_funnel_that_cannot_be_asked
    runner = FakeCommandRunner.new
    runner.stub "funnel status --json", exit_status: 1, stderr: "tailscaled is not running", once: true
    runner.stub "funnel status --json", stdout: funnel_status("/bc5/abc")
    ticks = Queue.new
    monitor = monitor(runner, wait: ->(_seconds) { ticks.pop })

    monitor.start
    2.times { ticks << true }
    deadline = Time.now + 2
    sleep 0.01 while runner.commands_matching(/funnel status/).length < 2 && Time.now < deadline

    assert_equal 2, runner.commands_matching(/funnel status/).length
    assert_match(/funnel check failed: `tailscale funnel status` failed: tailscaled is not running/, @logs.string)
    assert_predicate monitor.instance_variable_get(:@thread), :alive?
  ensure
    monitor&.stop
  end

  private
    def monitor(runner, wait: ->(_seconds) { })
      tunnel = BasecampAgentConnector::Tunnel.new(port: 4567, paths: [ "/bc5/abc" ], command_runner: runner)
      BasecampAgentConnector::FunnelMonitor.new(tunnel: tunnel, interval: 300, logger: @logs, wait: wait)
    end

    def funnel_status(*paths)
      handlers = paths.to_h { |path| [ path, { "Proxy" => "http://127.0.0.1:4567#{path}" } ] }
      JSON.generate("Web" => { "host.example.ts.net:443" => { "Handlers" => handlers } },
        "AllowFunnel" => { "host.example.ts.net:443" => true })
    end
end
