require "json"
require "securerandom"

# The Basecamp transport, as a self-contained route on the shared server: it owns
# its secret path, registers a webhook per project against the shared funnel, and
# turns each delivery into a verified, emitted event.
#
# Campfire chat is the one watched surface webhooks cannot carry (bc3 excludes
# chat kinds from relay outright), so chat-typed entries in `types` are split
# off into a ChatPoller instead of the webhook registration. Both sources feed
# identical pipelines: authorizer pre-filter, corroborating re-fetch,
# authoritative re-check, one STDOUT funnel.
class BasecampAgentConnector::Basecamp::Bridge
  # `--types` entries that select Campfire coverage rather than a registrable
  # webhook recording type. Chat::Line is the canonical spelling.
  CHAT_TYPE = /\A(chat(::.+)?|campfire)\z/i

  def initialize(authorizer:, agent:, projects:, types:, basecamp_cli:, emitter:, logger: $stderr,
    chat_poll_interval: BasecampAgentConnector::Basecamp::ChatPoller::DEFAULT_INTERVAL)
    @authorizer = authorizer
    @agent = agent
    @projects = projects
    @webhook_types, @chat_types = partition_types(types)
    @basecamp_cli = basecamp_cli
    @emitter = emitter
    @logger = logger
    @chat_poll_interval = chat_poll_interval
    @secret = SecureRandom.hex(16)
    @webhooks = BasecampAgentConnector::Basecamp::Webhooks.new(basecamp_cli: basecamp_cli)
  end

  # No webhook types means no webhook ingress: without a mounted route, a
  # leaked or guessed path can't feed forged non-chat payloads to a connector
  # that was asked to watch chat only.
  def path
    "/bc5/#{@secret}" if @webhook_types.any?
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
      @webhooks.register_all(projects: @projects, url: url, types: @webhook_types.join(","))
      log "Listening for mentions of @#{agent_name} on #{@projects.length} project(s) at #{url}"
    end

    log "Trust: #{@authorizer.description}"
  end

  def handler
    lambda do |request|
      Thread.new do
        payload = JSON.parse(request.body)

        # Basecamp never delivers chat events by webhook, so a chat-kind payload
        # on this route is by definition not from Basecamp. The poller is the
        # sole chat source; refuse the impostor rather than corroborate it.
        if BasecampAgentConnector::Basecamp::Event.from_payload(payload).chat_kind?
          log "ignored chat-kind payload: Basecamp does not deliver chat webhooks"
        else
          pipeline.process(payload)
        end
      rescue JSON::ParserError => error
        log "ignored malformed payload: #{error.message}"
      rescue => error
        log "pipeline error: #{error.message}"
      end
    end
  end

  def teardown
    @chat_poller&.stop
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
