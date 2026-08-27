# Polls one Pings source on a thread, for the transport that has no other way to
# carry a ping.
#
# `connect` mounts webhooks on a blocking server, and Basecamp registers no
# webhook for chat of any kind, so a ping arrives there only if something keeps
# asking. This is that something: the same source, pipeline and emitted stream as
# `poll` uses, running beside the server rather than instead of it. Both write
# through the one Emitter, which is why that holds a lock.
class BasecampAgentConnector::Basecamp::PingWatcher
  DEFAULT_INTERVAL = 60

  def initialize(pings:, pipeline:, state:, interval: DEFAULT_INTERVAL, logger: $stderr)
    @pings = pings
    @pipeline = pipeline
    @state = state
    @interval = interval
    @logger = logger
    @running = false
  end

  # Seeding happens here rather than in the caller because a fresh state file and
  # a first round are the same moment for this source: without it, the first round
  # of a `connect` run would replay every conversation the agent is part of.
  def start
    @running = true
    @thread = Thread.new do
      seed_if_new
      round while @running
    end
    self
  end

  # Cut short rather than waited out. Teardown is already tearing down a funnel and
  # a webhook per project, and a thread sleeping out its last interval is a minute
  # of that spent doing nothing.
  def stop
    @running = false
    @thread&.wakeup
    @thread&.join 5
    @state.save
  end

  private
    def round
      poll
      wait
    end

    def poll
      @pings.payloads.each do |payload|
        @pipeline.process payload
      rescue BasecampAgentConnector::Basecamp::Verifier::Unreachable => error
        @pings.rollback payload
        log "#{error.message} - will retry next round"
      end
      @state.save
    rescue StandardError => error
      log "ping round failed: #{error.message}"
    end

    def wait
      @interval.times do
        break unless @running
        sleep 1
      end
    end

    def seed_if_new
      return unless @state.empty?

      @pings.seed
      @state.save
    end

    def log(message)
      @logger.puts message
    end
end
