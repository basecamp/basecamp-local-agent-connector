require "optparse"
require "securerandom"
require "socket"

class BasecampAgentConnector::CLI
  DEFAULT_TYPES = "Comment,Message,Kanban::Card"

  Options = Data.define(:trigger, :projects, :types, :port)

  def self.start(argv)
    new(parse_options(argv)).start
  rescue ArgumentError => error
    abort error.message
  end

  def self.parse_options(argv)
    arguments = argv.dup
    projects = []
    types = DEFAULT_TYPES
    port = nil

    OptionParser.new do |parser|
      parser.banner = "Usage: connect <trigger> [--project PROJECT]... [--types TYPES] [--port PORT]"
      parser.on("--project PROJECT", "Basecamp project name, URL, or ID (required; repeatable)") { |value| projects << value }
      parser.on("--types TYPES", "Comma-separated Basecamp event types") { |value| types = value }
      parser.on("--port PORT", Integer, "Local port for the webhook server") { |value| port = value }
    end.parse!(arguments)

    trigger = arguments.shift
    raise ArgumentError, "a trigger is required, e.g. `connect @agent --project \"My Project\"`" if trigger.nil? || trigger.empty?
    raise ArgumentError, "at least one --project is required (Basecamp webhooks are per-project)" if projects.empty?

    Options.new(trigger: trigger, projects: projects, types: types, port: port)
  end

  def initialize(options)
    @options = options
  end

  def start
    identity = resolve_identity
    port = @options.port || free_port
    secret = SecureRandom.hex(16)

    open_bridge(port: port, secret: secret, projects: @options.projects, types: @options.types)
    listen(identity: identity, port: port, secret: secret)
  ensure
    teardown
  end

  private
    def resolve_identity
      BasecampAgentConnector::Identity.resolve(basecamp_cli: basecamp_cli)
    rescue BasecampAgentConnector::BasecampCLI::Error => error
      abort "Could not authenticate with Basecamp: #{error.message}\nRun `basecamp auth login` and try again."
    end

    def open_bridge(port:, secret:, projects:, types:)
      @tunnel = BasecampAgentConnector::Tunnel.new(port: port, command_runner: command_runner)
      webhook_url = "#{@tunnel.start}/hook/#{secret}"

      @webhooks = BasecampAgentConnector::Webhooks.new(basecamp_cli: basecamp_cli)
      @webhooks.register_all(projects: projects, url: webhook_url, types: types)

      warn "Listening for `#{@options.trigger}` on #{projects.length} project(s) at #{webhook_url}"
    end

    def listen(identity:, port:, secret:)
      @server = BasecampAgentConnector::Server.new(port: port, secret: secret, handler: dispatcher(identity))
      install_signal_handlers
      @server.start
    end

    def dispatcher(identity)
      pipeline = build_pipeline(identity)

      lambda do |payload|
        Thread.new do
          pipeline.process(payload)
        rescue => error
          warn "pipeline error: #{error.message}"
        end
      end
    end

    def build_pipeline(identity)
      BasecampAgentConnector::Pipeline.new \
        trigger: @options.trigger,
        identity: identity,
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
