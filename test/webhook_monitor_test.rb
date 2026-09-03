require "test_helper"

class WebhookMonitorTest < Minitest::Test
  def setup
    @logs = StringIO.new
  end

  def test_check_remounts_the_funnel_and_then_restores_the_webhooks
    runner = FakeCommandRunner.new
    runner.stub "funnel status --json", stdout: "{}"
    runner.stub "--set-path", exit_status: 0
    runner.stub "webhooks show 555", stdout: envelope("id" => 555, "active" => false)
    runner.stub "webhooks update 555", stdout: envelope("id" => 555, "active" => true)

    monitor(runner, tunnel: tunnel(runner)).check

    remounted = runner.commands.index { |command| command.include?("--set-path") }
    reactivated = runner.commands.index { |command| command.include?("update") }
    assert_operator remounted, :<, reactivated
    assert_match(%r{funnel path /bc5/abc was no longer mounted.*remounted it}, @logs.string)
    assert_match(/webhook 555 on project 1 was DEACTIVATED by Basecamp.*Reactivated it in place/, @logs.string)
  end

  def test_check_is_quiet_when_everything_is_in_place
    runner = FakeCommandRunner.new
    runner.stub "funnel status --json", stdout: funnel_status("/bc5/abc")
    runner.stub "webhooks show 555", stdout: envelope("id" => 555, "active" => true)

    monitor(runner, tunnel: tunnel(runner)).check

    assert_empty @logs.string
    assert_empty runner.commands_matching(/set-path|webhooks update/)
  end

  def test_check_still_restores_the_webhooks_when_the_funnel_cannot_be_asked
    runner = FakeCommandRunner.new
    runner.stub "funnel status --json", exit_status: 1, stderr: "tailscaled is not running"
    runner.stub "webhooks show 555", stdout: envelope("id" => 555, "active" => false)
    runner.stub "webhooks update 555", stdout: envelope("id" => 555, "active" => true)

    monitor(runner, tunnel: tunnel(runner)).check

    assert_match(/funnel check failed: `tailscale funnel status` failed: tailscaled is not running/, @logs.string)
    assert_equal 1, runner.commands_matching(/webhooks update 555/).length
  end

  def test_check_without_a_tunnel_only_restores_the_webhooks
    runner = FakeCommandRunner.new
    runner.stub "webhooks show 555", stdout: envelope("id" => 555, "active" => true)

    monitor(runner, tunnel: nil).check

    assert_empty runner.commands_matching(/tailscale/)
    assert_equal 1, runner.commands_matching(/webhooks show 555/).length
  end

  def test_start_checks_nothing_before_the_first_interval_and_stop_ends_the_thread
    runner = FakeCommandRunner.new
    runner.stub "webhooks show 555", stdout: envelope("id" => 555, "active" => true)
    ticks = Queue.new
    monitor = monitor(runner, wait: ->(_seconds) { ticks.pop })

    monitor.start
    assert_empty runner.commands_matching(/webhooks show/)

    2.times { ticks << true }
    deadline = Time.now + 2
    sleep 0.01 while runner.commands_matching(/webhooks show/).empty? && Time.now < deadline
    refute_empty runner.commands_matching(/webhooks show/)

    monitor.stop
    refute monitor.instance_variable_get(:@thread)
  end

  def test_the_check_thread_survives_an_exception_escaping_a_check
    runner = FakeCommandRunner.new
    runner.stub "webhooks show 555", stdout: envelope("id" => 555, "active" => true)
    ticks = Queue.new
    checked = Queue.new
    monitor = monitor(runner, wait: ->(_seconds) { ticks.pop })
    attempts = 0
    monitor.define_singleton_method(:check) do
      attempts += 1
      checked << attempts
      raise "surprise" if attempts == 1
      super()
    end

    monitor.start
    ticks << true
    ticks << true
    checked.pop until attempts >= 2

    assert_match(/webhook check failed: surprise/, @logs.string)
    assert_predicate monitor.instance_variable_get(:@thread), :alive?
  ensure
    monitor&.stop
  end

  private
    def monitor(runner, tunnel: nil, wait: ->(_seconds) { })
      BasecampAgentConnector::Basecamp::WebhookMonitor.new \
        webhooks: registered_webhooks(runner),
        url: "https://host.example.ts.net/bc5/abc",
        types: "Comment",
        tunnel: tunnel,
        interval: 300,
        logger: @logs,
        wait: wait
    end

    def registered_webhooks(runner)
      runner.stub "webhooks create", stdout: envelope("id" => 555)
      BasecampAgentConnector::Basecamp::Webhooks.new(basecamp_cli: build_cli(runner), logger: @logs, wait: ->(_seconds) { }).tap do |webhooks|
        webhooks.register_all(projects: [ 1 ], url: "https://host.example.ts.net/bc5/abc", types: "Comment")
      end
    end

    def tunnel(runner)
      BasecampAgentConnector::Tunnel.new(port: 4567, paths: [ "/bc5/abc" ], command_runner: runner)
    end

    def funnel_status(*paths)
      handlers = paths.to_h { |path| [ path, { "Proxy" => "http://127.0.0.1:4567#{path}" } ] }
      JSON.generate("Web" => { "host.example.ts.net:443" => { "Handlers" => handlers } },
        "AllowFunnel" => { "host.example.ts.net:443" => true })
    end
end
