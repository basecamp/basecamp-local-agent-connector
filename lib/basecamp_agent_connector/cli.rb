require "optparse"
require "securerandom"
require "socket"

class BasecampAgentConnector::CLI
  DEFAULT_TYPES = "Comment,Message,Kanban::Card"

  Options = Data.define(:agent, :operator, :projects, :types, :port)

  def self.start(argv)
    new(parse_options(argv)).start
  rescue ArgumentError => error
    abort error.message
  end

  def self.parse_options(argv)
    arguments = argv.dup
    projects = []
    operator = nil
    types = DEFAULT_TYPES
    port = nil

    OptionParser.new do |parser|
      parser.banner = "Usage: connect @AGENT --project PROJECT [--operator PROFILE] [--types TYPES] [--port PORT]"
      parser.on("--project PROJECT", "Basecamp project name, URL, or ID (required; repeatable)") { |value| projects << value }
      parser.on("--operator PROFILE", "Profile whose user is allowed to trigger (default: CLI default profile)") { |value| operator = value }
      parser.on("--types TYPES", "Comma-separated Basecamp event types") { |value| types = value }
      parser.on("--port PORT", Integer, "Local port for the webhook server") { |value| port = value }
    end.parse!(arguments)

    agent = arguments.shift
    raise ArgumentError, "an agent is required, e.g. `connect @clawdito --project \"My Project\"`" if agent.nil? || agent.empty?
    raise ArgumentError, "at least one --project is required (Basecamp webhooks are per-project)" if projects.empty?

    Options.new(agent: normalize_agent(agent), operator: operator, projects: projects, types: types, port: port)
  end

  def self.normalize_agent(agent)
    agent.sub(/\A@/, "").downcase
  end

  def initialize(options)
    @options = options
  end

  def start
    agent = resolve_agent
    operator = resolve_operator
    warn_if_same_user(agent, operator)
    port = @options.port || free_port
    secret = SecureRandom.hex(16)

    open_bridge(port: port, secret: secret, projects: @options.projects, types: @options.types, agent: agent)
    listen(operator: operator, agent: agent, port: port, secret: secret)
  ensure
    teardown
  end

  private
    def resolve_agent
      BasecampAgentConnector::Identity.resolve(basecamp_cli: basecamp_cli, profile: @options.agent)
    rescue BasecampAgentConnector::BasecampCLI::Error => error
      abort "No usable local Basecamp profile '#{@options.agent}'.\n" \
        "Run `basecamp auth login --profile #{@options.agent}` and log in as that user, then retry.\n(#{error.message})"
    end

    def resolve_operator
      BasecampAgentConnector::Identity.resolve(basecamp_cli: basecamp_cli, profile: @options.operator)
    rescue BasecampAgentConnector::BasecampCLI::Error => error
      abort "Could not resolve the operator identity#{operator_label}: #{error.message}\nRun `basecamp auth login` and try again."
    end

    def operator_label
      @options.operator ? " (profile #{@options.operator})" : ""
    end

    def warn_if_same_user(agent, operator)
      if agent.same_user_as?(operator)
        warn "Warning: agent '#{agent.profile}' and the operator are the same Basecamp user (#{agent.email}). " \
          "Replies posted as the agent would re-trigger the connector — authenticate the agent profile as a distinct bot user."
      end
    end

    def open_bridge(port:, secret:, projects:, types:, agent:)
      @tunnel = BasecampAgentConnector::Tunnel.new(port: port, command_runner: command_runner)
      webhook_url = "#{@tunnel.start}/hook/#{secret}"

      @webhooks = BasecampAgentConnector::Webhooks.new(basecamp_cli: basecamp_cli)
      @webhooks.register_all(projects: projects, url: webhook_url, types: types)

      warn "Listening for mentions of @#{agent.name || agent.profile} on #{projects.length} project(s) at #{webhook_url}"
    end

    def listen(operator:, agent:, port:, secret:)
      @server = BasecampAgentConnector::Server.new(port: port, secret: secret, handler: dispatcher(operator, agent))
      install_signal_handlers
      @server.start
    end

    def dispatcher(operator, agent)
      pipeline = build_pipeline(operator, agent)

      lambda do |payload|
        Thread.new do
          pipeline.process(payload)
        rescue => error
          warn "pipeline error: #{error.message}"
        end
      end
    end

    def build_pipeline(operator, agent)
      BasecampAgentConnector::Pipeline.new \
        operator: operator,
        agent: agent,
        verifier: BasecampAgentConnector::Verifier.new(basecamp_cli: basecamp_cli),
        emitter: BasecampAgentConnector::Emitter.new
    end

    def install_signal_handlers
      %w[INT TERM].each do |signal|
        Signal.trap(signal) { @server.stop }
      end
    end

    def teardown
      @server&.stop
      @webhooks&.delete_all
      @tunnel&.stop
    end

    def free_port
      socket = TCPServer.new("127.0.0.1", 0)
      port = socket.addr[1]
      socket.close
      port
    end

    def command_runner
      @command_runner ||= BasecampAgentConnector::CommandRunner.new
    end

    def basecamp_cli
      @basecamp_cli ||= BasecampAgentConnector::BasecampCLI.new(command_runner: command_runner)
    end
end
