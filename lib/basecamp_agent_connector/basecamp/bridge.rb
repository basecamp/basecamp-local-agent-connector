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
# a BoostPoller over the agent's own received-boosts feed. Pings are infeasible
# twice over — a chat kind, in a Circle that is not a project to register
# against — so a PingPoller covers those from the agent's notification feed.
# All sources feed identical pipelines: authorizer pre-filter, corroborating
# re-fetch, authoritative re-check, one STDOUT funnel.
#
# The deliveries the webhook route never received are a source of their own: on
# the webhook re-check's tick a DeliveryReconciler reads each registration's own
# delivery history and replays the recorded body of every delivery that failed,
# through this same webhook pipeline (see DeliveryReconciler).
class BasecampAgentConnector::Basecamp::Bridge
  # `--types` entries that select Campfire coverage rather than a registrable
  # webhook recording type. Chat::Line is the canonical spelling.
  CHAT_TYPE = /\A(chat(::.+)?|campfire)\z/i

  def initialize(authorizer:, agent:, projects:, types:, basecamp_cli:, emitter:, operator: nil, logger: $stderr,
    chat_poll_interval: BasecampAgentConnector::Basecamp::ChatPoller::DEFAULT_INTERVAL,
    boost_poll_interval: BasecampAgentConnector::Basecamp::BoostPoller::DEFAULT_INTERVAL,
    ping_poll_interval: BasecampAgentConnector::Basecamp::PingPoller::DEFAULT_INTERVAL,
    webhook_check_interval: BasecampAgentConnector::Basecamp::WebhookMonitor::DEFAULT_INTERVAL,
    delivery_lookback: BasecampAgentConnector::Basecamp::DeliveryReconciler::DEFAULT_LOOKBACK)
    @authorizer = authorizer
    @agent = agent
    @operator = operator
    @projects = projects
    @webhook_types, @chat_types = partition_types(types)
    @basecamp_cli = basecamp_cli
    @emitter = emitter
    @logger = logger
    @chat_poll_interval = chat_poll_interval
    @boost_poll_interval = boost_poll_interval
    @ping_poll_interval = ping_poll_interval
    @webhook_check_interval = webhook_check_interval
    @delivery_lookback = delivery_lookback
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

  # Reaps the registrations abandoned runs left pointing at paths nothing
  # serves any more — on the projects *those* runs watched, not just the ones
  # this run does. A dead run's webhooks sit where it was watching, which this
  # run need not be. Returns the projects it could account for.
  def sweep_orphans(runs)
    @webhooks.delete_orphans(projects: @projects | runs.flat_map(&:projects), paths: runs.flat_map(&:paths))
  end

  def register(base_url:)
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
      url = "#{base_url}#{path}"
      types = @webhook_types.join(",")
      @webhooks.register_all(projects: @projects, url: url, types: types)
      log "Listening for mentions of @#{agent_name} on #{@projects.length} project(s) at #{url}"

      # Started before readiness is reported, but its first check is one
      # interval away, so nothing here races the funnel consumer.
      if @webhook_check_interval
        start_webhook_monitor(url: url, types: types)
        log "Re-checking those webhooks every #{@webhook_check_interval}s " \
          "(Basecamp deactivates a webhook after 10 failed deliveries, silently), and reconciling from their " \
          "delivery history any delivery of the last #{@delivery_lookback}s that never arrived"
      end
    end

    # The boost poller fetches nothing until its thread's first interval pass,
    # well after the funnel consumer has seen these readiness lines — so no
    # event can beat the watcher to the stream.
    if @boost_poll_interval
      boost_poller.start
      log "Polling @#{agent_name}'s received-boosts feed every #{@boost_poll_interval}s (boosts have no webhooks)"
    end

    # Same again for pings: discovery runs synchronously here so the room
    # count is accurate, but no line is read until the thread's first pass.
    if @ping_poll_interval
      pings = ping_poller.start
      log "Polling #{pings.length} Ping(s) with @#{agent_name} every #{@ping_poll_interval}s " \
        "(a Circle is not a project, so pings have no webhooks either)"
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
      # Chat and boost kinds, which Basecamp never delivers by webhook, are
      # refused by the webhook pipeline itself (see Pipeline), so the replay
      # path the DeliveryReconciler takes cannot skip that gate either.
      payload = JSON.parse(request.body)
      pipeline.process(payload)

      nil
    rescue BasecampAgentConnector::Basecamp::Client::TransientError => error
      log "could not corroborate event #{payload["id"]}: #{error.message}; answered 503 so Basecamp redelivers " \
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
    @ping_poller&.stop
    @webhook_monitor&.stop
    @webhooks.delete_all
  end

  private
    def partition_types(types)
      types.split(",").map(&:strip).reject(&:empty?).partition { |type| !type.match?(CHAT_TYPE) }
    end

    def pipeline
      @pipeline ||= build_pipeline(webhook: true)
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

    # Like the other two: its own pipeline so ping line ids, chat line ids and
    # webhook event ids never share a dedupe space; trust components are the
    # same instances.
    def ping_poller
      @ping_poller ||= BasecampAgentConnector::Basecamp::PingPoller.new \
        basecamp_cli: @basecamp_cli,
        pipeline: build_pipeline,
        agent: @agent,
        interval: @ping_poll_interval,
        logger: @logger
    end

    def start_webhook_monitor(url:, types:)
      @webhook_monitor = BasecampAgentConnector::Basecamp::WebhookMonitor.new \
        webhooks: @webhooks,
        url: url,
        types: types,
        interval: @webhook_check_interval,
        reconciler: delivery_reconciler,
        logger: @logger
      @webhook_monitor.start
    end

    # The reconciler shares the webhook route's own pipeline, deliberately: one
    # per-event.id suppression space covers both, so a delivery recovered here
    # and the same delivery arriving live — a Basecamp retry, or one still in
    # flight when the history was read — fire once between them, not twice;
    # and every gate that pipeline applies, the webhook-only kind refusal
    # included, applies to a replay exactly as to a live delivery.
    def delivery_reconciler
      BasecampAgentConnector::Basecamp::DeliveryReconciler.new \
        webhooks: @webhooks,
        pipeline: pipeline,
        lookback: @delivery_lookback,
        logger: @logger
    end

    def build_pipeline(webhook: false)
      BasecampAgentConnector::Basecamp::Pipeline.new \
        authorizer: @authorizer,
        agent: @agent,
        verifier: verifier,
        emitter: @emitter,
        webhook: webhook,
        logger: @logger
    end

    def verifier
      @verifier ||= BasecampAgentConnector::Basecamp::Verifier.new(basecamp_cli: @basecamp_cli, agent: @agent,
        operator: @operator)
    end

    def agent_name
      @agent.name || @agent.profile
    end

    def log(message)
      @logger.puts message
    end
end
