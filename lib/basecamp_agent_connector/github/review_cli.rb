require "optparse"
require "securerandom"
require "socket"

class BasecampAgentConnector::GitHub::ReviewCLI
  DEFAULT_EVENTS = "pull_request_review"

  Options = Data.define(:repos, :events, :port)

  def self.start(argv)
    new(parse_options(argv)).start
  rescue ArgumentError => error
    abort error.message
  end

  def self.parse_options(argv)
    arguments = argv.dup
    events = DEFAULT_EVENTS
    port = nil

    OptionParser.new do |parser|
      parser.banner = "Usage: gh-review OWNER/REPO [OWNER/REPO ...] [--events EVENTS] [--port PORT]"
      parser.on("--events EVENTS", "Comma-separated GitHub webhook events") { |value| events = value }
      parser.on("--port PORT", Integer, "Local port for the webhook server") { |value| port = value }
    end.parse!(arguments)

    raise ArgumentError, "at least one OWNER/REPO is required, e.g. `gh-review basecamp/bc3`" if arguments.empty?

    Options.new(repos: arguments, events: events, port: port)
  end

  def initialize(options)
    @options = options
  end

  def start
    port = @options.port || free_port
    path_secret = SecureRandom.hex(16)
    hmac_secret = SecureRandom.hex(32)

    open_bridge(port: port, path_secret: path_secret, hmac_secret: hmac_secret)
    listen(port: port, path_secret: path_secret, hmac_secret: hmac_secret)
  ensure
    teardown
  end

  private
    def open_bridge(port:, path_secret:, hmac_secret:)
      @tunnel = BasecampAgentConnector::Tunnel.new(port: port, command_runner: command_runner)
      webhook_url = "#{@tunnel.start}/gh/#{path_secret}"

      @webhooks = BasecampAgentConnector::GitHub::Webhooks.new(github_cli: github_cli)
      @webhooks.register_all(repos: @options.repos, url: webhook_url, secret: hmac_secret, events: events_list)

      warn "Listening for #{@options.events} on #{@options.repos.length} repo(s) at #{webhook_url}"
    end

    def listen(port:, path_secret:, hmac_secret:)
      @server = BasecampAgentConnector::Server.new(port: port, path: "/gh/#{path_secret}", handler: dispatcher(hmac_secret))
      install_signal_handlers
      @server.start
    end

    def dispatcher(hmac_secret)
      pipeline = build_pipeline(hmac_secret)

      lambda do |request|
        Thread.new do
          pipeline.process(body: request.body, signature: request.header("X-Hub-Signature-256"))
        rescue => error
          warn "pipeline error: #{error.message}"
        end
      end
    end

    def build_pipeline(hmac_secret)
      BasecampAgentConnector::GitHub::ReviewPipeline.new \
        secret: hmac_secret,
        verifier: BasecampAgentConnector::GitHub::ReviewVerifier.new(github_cli: github_cli),
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

    def events_list
      @options.events.split(",").map(&:strip)
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

    def github_cli
      @github_cli ||= BasecampAgentConnector::GitHub::Client.new(command_runner: command_runner)
    end
end
