# Keeps the webhook registrations alive for the life of the run. A
# registration is made once at startup, but Basecamp deactivates a webhook
# after 10 failed deliveries (bc3 Webhook::DeliveryJob) and says nothing, and
# the pollers keep working through it, so the connector looks healthy while
# every mention goes unheard. On an interval each registration is re-read and
# restored (see Webhooks#restore), and anything found wrong is logged loudly.
# The funnel those deliveries need is the FunnelMonitor's to keep mounted.
class BasecampAgentConnector::Basecamp::WebhookMonitor
  DEFAULT_INTERVAL = 300

  def initialize(webhooks:, url:, types:, interval: DEFAULT_INTERVAL, logger: $stderr,
    wait: ->(seconds) { sleep seconds })
    @webhooks = webhooks
    @url = url
    @types = types
    @interval = interval
    @logger = logger
    @wait = wait
    @stopping = false
    @checking = Mutex.new
  end

  def start
    @thread = Thread.new { check_loop }
  end

  # A check in flight is let finish before the thread is killed: killing it
  # mid-restore would leave a replacement webhook Basecamp created but the
  # registrations never recorded, for teardown to miss. Taking the lock
  # waits for that, so the kill only ever lands in the interval's sleep;
  # the wait is bounded by the CLI's own timeouts, like an in-flight
  # delivery's.
  def stop
    @stopping = true

    if @thread
      @checking.synchronize { @thread.kill }
      log "webhook check thread did not stop within 5s" if @thread.join(5).nil?
      @thread = nil
    end
  end

  def check
    @checking.synchronize do
      @webhooks.restore(url: @url, types: @types) unless @stopping
    end
  end

  private
    # An exception escaping a check must cost one tick, not the rest of the
    # session's coverage.
    def check_loop
      until @stopping
        @wait.call(@interval)

        begin
          check
        rescue => error
          log "webhook check failed: #{error.message}"
        end
      end
    end

    def log(message)
      @logger.puts message
    end
end
