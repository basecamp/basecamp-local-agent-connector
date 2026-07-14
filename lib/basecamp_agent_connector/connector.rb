require "optparse"
require "socket"

# The unified entry point. Opens ONE Tailscale Funnel and ONE local server, and
# mounts each requested transport (Basecamp projects and/or GitHub repos) as a
# route on it. Basecamp and GitHub watching therefore run simultaneously over a
# single funnel — the per-machine funnel is no longer a bottleneck.
class BasecampAgentConnector::Connector
  DEFAULT_EVENTS = "pull_request_review"

  Options = Data.define(:agent, :connection_token, :host, :repos, :events, :port) do
    def watch_basecamp?
      !agent.nil? && !connection_token.nil?
    end

    def watch_github?
      repos.any?
    end
  end

  def self.start(argv)
    new(parse_options(argv)).start
  rescue ArgumentError => error
    abort error.message
  end

  def self.parse_options(argv)
    arguments = argv.dup
    repos = []
    connection_token = nil
    host = nil
    events = DEFAULT_EVENTS
    port = nil

    OptionParser.new do |parser|
      parser.banner = "Usage: connect [@AGENT --connection-token TOKEN --host URL] [--repo OWNER/REPO]... [--events EVENTS] [--port PORT]"
      parser.on("--connection-token TOKEN", "Per-(operator, agent) Agent Channel connection token") { |value| connection_token = value }
      parser.on("--host URL", "Basecamp base URL for this account, e.g. https://3.basecamp.com/1234567") { |value| host = value }
      parser.on("--repo OWNER/REPO", "GitHub repo to watch for reviews (repeatable)") { |value| repos << value }
      parser.on("--events EVENTS", "Comma-separated GitHub webhook events") { |value| events = value }
      parser.on("--port PORT", Integer, "Local port for the GitHub webhook server") { |value| port = value }
    end.parse!(arguments)

    agent = normalize_agent(arguments.shift)

    unless (agent && connection_token) || repos.any?
      raise ArgumentError, "watch something: pass @AGENT with --connection-token (Basecamp) and/or --repo (GitHub)"
    end
    raise ArgumentError, "connecting to Basecamp needs both @AGENT and --connection-token" if agent && connection_token.nil?
    raise ArgumentError, "connecting to Basecamp needs --host (the account base URL)" if agent && connection_token && host.nil?

    Options.new(agent: agent, connection_token: connection_token, host: host, repos: repos, events: events_list(events), port: port)
  end

  def self.normalize_agent(agent)
    agent&.sub(/\A@/, "")&.downcase
  end

  def self.events_list(events)
    events.split(",").map(&:strip)
  end

  def initialize(options)
    @options = options
  end

  # Basecamp now rides an outbound Agent Channel connection (no funnel, no
  # webhooks); only GitHub still needs the inbound funnel + server. When both are
  # watched the channel client runs on its own thread beside the GitHub server.
  def start
    channel_thread = Thread.new { start_channel_client } if @options.watch_basecamp?
    start_github_server if @options.watch_github?
    channel_thread&.join
  ensure
    teardown
  end

  private
    def start_channel_client
      channel_client.start
    rescue => error
      warn "Agent Channel client stopped: #{error.message}"
    end

    def channel_client
      @channel_client ||= BasecampAgentConnector::Channel::Client.new \
        api: channel_api, cursor: channel_cursor, emitter: emitter, socket: channel_socket
    end

    def channel_api
      BasecampAgentConnector::Channel::Api.new(base_url: @options.host, connection_token: @options.connection_token)
    end

    def channel_cursor
      BasecampAgentConnector::Channel::Cursor.new(agent: @options.agent, operator: @options.connection_token[0, 8])
    end

    def channel_socket
      BasecampAgentConnector::Channel::Socket.new(cable_url: cable_url, connection_token: @options.connection_token)
    end

    def cable_url
      URI(@options.host).then { |uri| "#{uri.scheme == 'https' ? 'wss' : 'ws'}://#{uri.host}/cable" }
    end

    def start_github_server
      port = @options.port || free_port
      @tunnel = BasecampAgentConnector::Tunnel.new(port: port, command_runner: command_runner)
      base_url = @tunnel.start

      @github_bridge = github_bridge
      @github_bridge.register(base_url: base_url)

      @server = BasecampAgentConnector::Server.new(port: port, routes: { @github_bridge.path => @github_bridge.handler })
      install_signal_handlers
      @server.start
    end

    def github_bridge
      BasecampAgentConnector::GitHub::Bridge.new \
        repos: @options.repos, events: @options.events,
        github_cli: github_cli, emitter: emitter
    end

    def install_signal_handlers
      %w[INT TERM].each do |signal|
        Signal.trap(signal) { @server.stop }
      end
    end

    def teardown
      @server&.stop
      @github_bridge&.teardown
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

    def github_cli
      @github_cli ||= BasecampAgentConnector::GitHub::Client.new(command_runner: command_runner)
    end

    def emitter
      @emitter ||= BasecampAgentConnector::Emitter.new
    end
end
