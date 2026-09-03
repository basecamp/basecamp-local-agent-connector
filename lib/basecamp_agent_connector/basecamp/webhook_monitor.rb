# Keeps the webhook registrations deliverable for the life of the run. A
# registration is made once at startup, but Basecamp deactivates a webhook
# after 10 failed deliveries (bc3 Webhook::DeliveryJob), and the funnel path
# those deliveries need can drop out from under the run — and neither says so.
# The pollers keep working through both, so the connector looks healthy while
# every mention goes unheard. On an interval, the funnel's paths are checked
# and remounted, then each registration is re-read and restored (see
# Webhooks#restore), and anything found wrong is logged loudly.
class BasecampAgentConnector::Basecamp::WebhookMonitor
  DEFAULT_INTERVAL = 300

  def initialize(webhooks:, url:, types:, tunnel: nil, interval: DEFAULT_INTERVAL, logger: $stderr,
    wait: ->(seconds) { sleep seconds })
    @webhooks = webhooks
    @url = url
    @types = types
    @tunnel = tunnel
    @interval = interval
    @logger = logger
    @wait = wait
    @stopping = false
  end

  def start
    @thread = Thread.new { check_loop }
  end

  def stop
    @stopping = true

    if @thread
      @thread.kill
      # Bounded, not guaranteed: a kill lands between CLI calls instantly, but
      # a thread mid-subprocess dies only when the child returns. The process
      # is tearing down anyway, so make any residue visible rather than block.
      log "webhook check thread did not stop within 5s" if @thread.join(5).nil?
      @thread = nil
    end
  end

  # Funnel first: a webhook reactivated toward an unmounted path only earns
  # its next ten failures.
  def check
    unless @stopping
      remount_funnel
      @webhooks.restore(url: @url, types: @types)
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

    # A funnel that can't be asked is logged and the webhooks still checked:
    # a reactivation is worth doing even when the funnel's state is unknown.
    def remount_funnel
      Array(@tunnel&.remount_missing).each do |path|
        log "funnel path #{path} was no longer mounted (a `tailscale funnel reset`, or tailscaled lost its serve " \
          "config); remounted it — deliveries in between failed, and bc3 deactivates a webhook after 10 of those"
      end
    rescue BasecampAgentConnector::Tunnel::Error => error
      log "funnel check failed: #{error.message}"
    end

    def log(message)
      @logger.puts message
    end
end
