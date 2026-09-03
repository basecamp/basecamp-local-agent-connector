require "json"
require "securerandom"

# The Basecamp transport, as a self-contained route on the shared server: it owns
# its secret path, registers a webhook per project against the shared funnel, and
# turns each delivery into a verified, emitted event.
#
# Campfire chat is the one watched surface webhooks cannot carry (bc3 excludes
# chat kinds from relay outright), so chat-typed entries in `types` are split
# off into a ChatPoller instead of the webhook registration. Boosts are just as
# webhook-infeasible (a Boost creates no Event in bc3), so the bridge also runs
# a BoostPoller over the agent's own received-boosts feed. All sources feed
# identical pipelines: authorizer pre-filter, corroborating re-fetch,
# authoritative re-check, one STDOUT funnel.
class BasecampAgentConnector::Basecamp::Bridge
  # `--types` entries that select Campfire coverage rather than a registrable
  # webhook recording type. Chat::Line is the canonical spelling.
  CHAT_TYPE = /\A(chat(::.+)?|campfire)\z/i

  def initialize(authorizer:, agent:, projects:, types:, basecamp_cli:, emitter:, logger: $stderr,
    chat_poll_interval: BasecampAgentConnector::Basecamp::ChatPoller::DEFAULT_INTERVAL,
    boost_poll_interval: BasecampAgentConnector::Basecamp::BoostPoller::DEFAULT_INTERVAL,
    webhook_check_interval: BasecampAgentConnector::Basecamp::WebhookMonitor::DEFAULT_INTERVAL)
    @authorizer = authorizer
    @agent = agent
    @projects = projects
    @webhook_types, @chat_types = partition_types(types)
    @basecamp_cli = basecamp_cli
    @emitter = emitter
    @logger = logger
    @chat_poll_interval = chat_poll_interval
    @boost_poll_interval = boost_poll_interval
    @webhook_check_interval = webhook_check_interval
    @secret = SecureRandom.hex(16)
    @webhooks = BasecampAgentConnector::Basecamp::Webhooks.new(basecamp_cli: basecamp_cli)
  end

  # No webhook types means no webhook ingress: without a mounted route, a
  # leaked or guessed path can't feed forged non-chat payloads to a connector
  # that was asked to watch chat only.
  def path
    "/bc5/#{@secret}" if @webhook_types.any?
  end

  # Paths this bridge owns, for the run registry to record. Same list the
  # server mounts; a chat-only bridge owns none.
  def paths
    [ path ].compact
  end

  # `tunnel` is the funnel the webhooks deliver through, for the monitor to
  # keep mounted; nil when the caller has none to check.
  def register(base_url:, orphan_paths: [], tunnel: nil)
    # Chat first: webhook registration opens deliveries toward a server that
    # isn't listening yet, so don't widen that window by discovering chats
    # after it. The poller emits nothing until its thread's first interval
    # pass, well after the funnel consumer has seen the readiness lines.
    if @chat_types.any?
      rooms = chat_poller.start
      log "Polling #{rooms.length} Campfire(s) for @#{agent_name} mentions every #{@chat_poll_interval}s " \
        "(chat lines have no webhooks)"
    end

    if @webhook_types.any?
      # Before adding ours, reap the registrations a dead run of ours left
      # pointing at a path nothing serves any more. Only paths the registry
      # attributed to an exited run reach here.
      @webhooks.delete_orphans(projects: @projects, paths: orphan_paths)

      url = "#{base_url}#{path}"
      types = @webhook_types.join(",")
      @webhooks.register_all(projects: @projects, url: url, types: types)
      log "Listening for mentions of @#{agent_name} on #{@projects.length} project(s) at #{url}"

      # Started before readiness is reported, but its first check is one
      # interval away, so nothing here races the funnel consumer.
      if @webhook_check_interval
        start_webhook_monitor(url: url, types: types, tunnel: tunnel)
        log "Re-checking those webhooks every #{@webhook_check_interval}s " \
          "(Basecamp deactivates a webhook after 10 failed deliveries, silently)"
      end
    end

    # The boost poller fetches nothing until its thread's first interval pass,
    # well after the funnel consumer has seen these readiness lines — so no
    # event can beat the watcher to the stream.
    if @boost_poll_interval
      boost_poller.start
      log "Polling @#{agent_name}'s received-boosts feed every #{@boost_poll_interval}s (boosts have no webhooks)"
    end

    log "Trust: #{@authorizer.description}"
  end

  # Each delivery is verified on the request thread and answered with its
  # verdict: 200 once the event is settled (emitted, dropped, or a
  # duplicate), 503 when Basecamp could not be asked. bc3 retries any
  # non-2xx delivery (Webhook::DeliveryJob: polynomially_longer backoff,
  # 10 attempts, then the webhook is deactivated), so a 503 is a request
  # for redelivery — of an event whose id the pipeline has forgotten, so the
  # redelivery gets a fresh attempt. Everything else answers 200: an
  # impostor payload, a malformed body, and a pipeline bug are settled here,
  # and redelivering them would only repeat the same outcome. Overrunning
  # bc3's 10s delivery timeout is harmless (a timed-out delivery is
  # redelivered and then deduped or re-verified), just wasteful.
  #
  # A failure that stays transient through all 10 attempts (~4.3h: a
  # revoked credential reports auth_required on every call, exactly like the
  # keyring race) ends with bc3 deactivating the webhook, silently. The
  # WebhookMonitor reactivates it on its next check, but a credential still
  # broken just fails the next ten deliveries too, so the 503 log line names
  # the remedy — fix the CLI's credentials. Which call could not be answered
  # — the recording fetch, or the subscriber lookup after it — is in the
  # error's message, which names the failed command.
  #
  # Because the work is on the request thread, shutdown (WEBrick joins its
  # request threads before `start` returns) waits for in-flight deliveries
  # to be answered before teardown deletes the webhooks, so none is lost to
  # a Ctrl-C. The wait is bounded only by the CLI's own timeouts, which on
  # a stalled network can run to minutes.
  def handler
    lambda do |request|
      payload = JSON.parse(request.body)

      # Basecamp never delivers chat or boost events by webhook, so either
      # kind on this route is by definition not from Basecamp. The pollers
      # are the sole sources; refuse the impostor rather than corroborate it
      # (or let it replay a real boost through this pipeline's separate dedupe).
      event = BasecampAgentConnector::Basecamp::Event.from_payload(payload)
      if event.chat_kind?
        log "ignored chat-kind payload: Basecamp does not deliver chat webhooks"
      elsif event.boost?
        log "ignored boost-kind payload: Basecamp does not deliver boost webhooks"
      else
        pipeline.process(payload)
      end

      nil
    rescue BasecampAgentConnector::Basecamp::Client::TransientError => error
      log "could not corroborate event #{event.id}: #{error.message}; answered 503 so Basecamp redelivers " \
        "(bc3 deactivates the webhook after 10 failed deliveries: if this repeats, check `basecamp auth status " \
        "--profile #{@agent.profile}` — the webhook check reactivates the webhook, but not the credentials)"
      503
    rescue JSON::ParserError => error
      log "ignored malformed payload: #{error.message}"
      nil
    rescue => error
      log "pipeline error: #{error.message}"
      nil
    end
  end

  def teardown
    @chat_poller&.stop
    @boost_poller&.stop
    @webhook_monitor&.stop
    @webhooks.delete_all
  end

  private
    def partition_types(types)
      types.split(",").map(&:strip).reject(&:empty?).partition { |type| !type.match?(CHAT_TYPE) }
    end

    def pipeline
      @pipeline ||= build_pipeline
    end

    # The poller gets its own pipeline so chat line ids and webhook event ids
    # never share a dedupe space; trust components are the same instances.
    def chat_poller
      @chat_poller ||= BasecampAgentConnector::Basecamp::ChatPoller.new \
        basecamp_cli: @basecamp_cli,
        pipeline: build_pipeline,
        projects: @projects,
        interval: @chat_poll_interval,
        logger: @logger
    end

    # Like the chat poller: its own pipeline so boost ids and webhook event
    # ids never share a dedupe space; trust components are the same instances.
    def boost_poller
      @boost_poller ||= BasecampAgentConnector::Basecamp::BoostPoller.new \
        basecamp_cli: @basecamp_cli,
        pipeline: build_pipeline,
        agent: @agent,
        interval: @boost_poll_interval,
        logger: @logger
    end

    def start_webhook_monitor(url:, types:, tunnel:)
      @webhook_monitor = BasecampAgentConnector::Basecamp::WebhookMonitor.new \
        webhooks: @webhooks,
        url: url,
        types: types,
        tunnel: tunnel,
        interval: @webhook_check_interval,
        logger: @logger
      @webhook_monitor.start
    end

    def build_pipeline
      BasecampAgentConnector::Basecamp::Pipeline.new \
        authorizer: @authorizer,
        agent: @agent,
        verifier: verifier,
        emitter: @emitter,
        logger: @logger
    end

    def verifier
      @verifier ||= BasecampAgentConnector::Basecamp::Verifier.new(basecamp_cli: @basecamp_cli, agent: @agent)
    end

    def agent_name
      @agent.name || @agent.profile
    end

    def log(message)
      @logger.puts message
    end
end
