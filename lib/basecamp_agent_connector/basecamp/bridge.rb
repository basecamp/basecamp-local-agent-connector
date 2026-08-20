require "json"
require "securerandom"

# The Basecamp transport, as a self-contained route on the shared server: it owns
# its secret path, registers a webhook per project against the shared funnel, and
# turns each delivery into a verified, emitted event.
class BasecampAgentConnector::Basecamp::Bridge
  def initialize(operator:, agent:, projects:, types:, basecamp_cli:, emitter:, watched_columns: [], logger: $stderr)
    @operator = operator
    @agent = agent
    @projects = projects
    @types = types
    @watched_columns = watched_columns
    @basecamp_cli = basecamp_cli
    @emitter = emitter
    @logger = logger
    @secret = SecureRandom.hex(16)
    @webhooks = BasecampAgentConnector::Basecamp::Webhooks.new(basecamp_cli: basecamp_cli)
  end

  def path
    "/hook/#{@secret}"
  end

  def register(base_url:)
    url = "#{base_url}#{path}"
    @webhooks.register_all(projects: @projects, url: url, types: @types)
    log "Listening for mentions of @#{@agent.name || @agent.profile} on #{@projects.length} project(s) at #{url}#{watched_columns_notice}"
  end

  def handler
    lambda do |request|
      Thread.new do
        pipeline.process(JSON.parse(request.body))
      rescue JSON::ParserError => error
        log "ignored malformed payload: #{error.message}"
      rescue => error
        log "pipeline error: #{error.message}"
      end
    end
  end

  def teardown
    @webhooks.delete_all
  end

  private
    def pipeline
      @pipeline ||= BasecampAgentConnector::Basecamp::Pipeline.new \
        operator: @operator,
        agent: @agent,
        verifier: BasecampAgentConnector::Basecamp::Verifier.new(basecamp_cli: @basecamp_cli, agent: @agent),
        emitter: @emitter,
        watched_columns: @watched_columns
    end

    def watched_columns_notice
      return "" if @watched_columns.empty?

      ", and new cards in column(s) #{@watched_columns.join(', ')}"
    end

    def log(message)
      @logger.puts message
    end
end
