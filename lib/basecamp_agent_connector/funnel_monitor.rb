# Keeps the run's funnel paths mounted for as long as it runs. A path is
# mounted once at startup, but a `tailscale funnel reset` by another tool, or
# a serve config that didn't survive tailscaled, takes it down without a word:
# the local server keeps listening and nothing reaches it. Basecamp deliveries
# then fail toward the webhook's deactivation, and GitHub's — which are never
# redelivered — are simply lost. On an interval the funnel is asked what it
# serves and any of this run's paths it has lost is remounted, loudly.
class BasecampAgentConnector::FunnelMonitor
  def initialize(tunnel:, interval:, logger: $stderr, wait: ->(seconds) { sleep seconds })
    @tunnel = tunnel
    @interval = interval
    @logger = logger
    @wait = wait
    @stopping = false
    @checking = Mutex.new
  end

  def start
    @thread = Thread.new { check_loop }
  end

  # A check in flight finishes before the kill, which then lands in the
  # interval's sleep — a remount half done at teardown would be undone by
  # the tunnel's own stop a moment later anyway, but not a remount that
  # lands after it.
  def stop
    @stopping = true

    if @thread
      @checking.synchronize { @thread.kill }
      log "funnel check thread did not stop within 5s" if @thread.join(5).nil?
      @thread = nil
    end
  end

  def check
    @checking.synchronize do
      unless @stopping
        @tunnel.remount_missing.each do |path|
          log "funnel path #{path} was no longer mounted (a `tailscale funnel reset`, or tailscaled lost its serve " \
            "config); remounted it — deliveries in between failed, and Basecamp deactivates a webhook after 10 of those"
        end
      end
    end
  end

  private
    def check_loop
      until @stopping
        @wait.call(@interval)

        begin
          check
        rescue => error
          log "funnel check failed: #{error.message}"
        end
      end
    end

    def log(message)
      @logger.puts message
    end
end
