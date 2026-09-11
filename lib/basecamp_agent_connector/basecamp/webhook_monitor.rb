# Keeps the webhook registrations alive for the life of the run. A
# registration is made once at startup, but Basecamp deactivates a webhook
# after 10 failed deliveries (bc3 Webhook::DeliveryJob) and says nothing, and
# the pollers keep working through it, so the connector looks healthy while
# every mention goes unheard. On an interval each registration is re-read and
# restored (see Webhooks#restore), and anything found wrong is logged loudly.
# The funnel those deliveries need is the FunnelMonitor's to keep mounted.
class BasecampAgentConnector::Basecamp::WebhookMonitor
  DEFAULT_INTERVAL = 300

  def initialize(webhooks:, url:, types:, interval: DEFAULT_INTERVAL, reconciler: nil, logger: $stderr,
    wait: ->(seconds) { sleep seconds })
    @webhooks = webhooks
    @url = url
    @types = types
    @interval = interval
    @reconciler = reconciler
    @logger = logger
    @wait = wait
    @stopping = false
    @checking = Mutex.new
  end

  def start
    @thread = Thread.new { check_loop }
  end

  # The unit of a check in flight — the restore, one delivery history read,
  # one reconciled delivery — is let finish before the thread is killed:
  # killing it mid-restore would leave a replacement webhook Basecamp created
  # but the registrations never recorded, for teardown to miss. Taking the
  # lock waits for that one unit, so the kill only ever lands between units
  # or in the interval's sleep. It never waits for the rest of a pass: a
  # reconciliation pass can hold twenty-five failed deliveries per webhook,
  # each a verification bounded only by the CLI's own timeouts, and a pass in
  # progress stops at the next unit instead. The one wait left is bounded like
  # an in-flight delivery's.
  def stop
    @stopping = true

    if @thread
      @checking.synchronize { @thread.kill }
      log "webhook check thread did not stop within 5s" if @thread.join(5).nil?
      @thread = nil
    end
  end

  # Restore first: reconciling against a webhook whose registration is gone
  # would read the history of an id Basecamp no longer has.
  def check
    if guarded { @webhooks.restore(url: @url, types: @types) }
      @reconciler&.reconcile(guard: method(:guarded))
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

    # Runs one unit of a check under the lock unless a stop has begun, and
    # answers whether it ran — so a pass ends at the first unit a stop reaches.
    def guarded
      @checking.synchronize do
        unless @stopping
          yield
          true
        end
      end
    end

    def log(message)
      @logger.puts message
    end
end
