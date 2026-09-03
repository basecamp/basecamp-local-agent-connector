require "test_helper"

class WebhookMonitorTest < Minitest::Test
  def setup
    @logs = StringIO.new
  end

  def test_check_restores_the_registrations
    runner = FakeCommandRunner.new
    runner.stub "webhooks show 555", stdout: envelope("id" => 555, "active" => false)
    runner.stub "webhooks update 555", stdout: envelope("id" => 555, "active" => true)

    monitor(runner).check

    assert_equal 1, runner.commands_matching(/webhooks update 555/).length
    assert_match(/webhook 555 on project 1 was DEACTIVATED by Basecamp.*Reactivated it in place/, @logs.string)
  end

  def test_check_is_quiet_when_everything_is_in_place
    runner = FakeCommandRunner.new
    runner.stub "webhooks show 555", stdout: envelope("id" => 555, "active" => true)

    monitor(runner).check

    assert_empty @logs.string
    assert_empty runner.commands_matching(/webhooks update/)
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

  # Killed mid-restore, the thread would leave a replacement Basecamp created
  # but the registrations never recorded; stop waits for the check instead,
  # so teardown deletes the replacement and not the id it replaced.
  def test_stop_lets_a_check_in_flight_finish_so_teardown_deletes_what_it_registered
    runner = PausingCommandRunner.new(/webhooks create/)
    webhooks = registered_webhooks(runner)
    runner.stub "webhooks create", stdout: envelope("id" => 556)
    runner.stub "webhooks show 555", stdout: error_envelope("not_found", "Resource not found: webhook 555"), exit_status: 2
    runner.stub "webhooks delete", exit_status: 0
    ticks = Queue.new
    monitor = monitor(runner, webhooks: webhooks, wait: ->(_seconds) { ticks.pop })
    runner.arm

    monitor.start
    ticks << true
    runner.paused.pop
    stopper = Thread.new { monitor.stop }
    sleep 0.05
    assert_predicate stopper, :alive?

    runner.resume << true
    stopper.join(2)
    refute_predicate stopper, :alive?
    webhooks.delete_all

    deletions = runner.commands_matching(/webhooks delete/)
    assert_equal 1, deletions.length
    assert_includes deletions.first, "556"
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

  # Once armed, blocks inside the matching command until released, to hold a
  # check in flight.
  class PausingCommandRunner < FakeCommandRunner
    attr_reader :paused, :resume

    def initialize(pattern)
      super()
      @pattern = pattern
      @armed = false
      @paused = Queue.new
      @resume = Queue.new
    end

    def arm
      @armed = true
    end

    def run(*command)
      if @armed && command.join(" ").match?(@pattern)
        @paused << true
        @resume.pop
      end

      super
    end
  end

  private
    def monitor(runner, webhooks: registered_webhooks(runner), wait: ->(_seconds) { })
      BasecampAgentConnector::Basecamp::WebhookMonitor.new \
        webhooks: webhooks,
        url: "https://host.example.ts.net/bc5/abc",
        types: "Comment",
        interval: 300,
        logger: @logs,
        wait: wait
    end

    def registered_webhooks(runner)
      runner.stub "webhooks create", stdout: envelope("id" => 555), once: true
      BasecampAgentConnector::Basecamp::Webhooks.new(basecamp_cli: build_cli(runner), logger: @logs, wait: ->(_seconds) { }).tap do |webhooks|
        webhooks.register_all(projects: [ 1 ], url: "https://host.example.ts.net/bc5/abc", types: "Comment")
      end
    end
end
