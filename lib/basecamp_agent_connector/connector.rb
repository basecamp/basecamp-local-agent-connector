require "optparse"
require "socket"

# The unified entry point. Opens ONE Tailscale Funnel and ONE local server, and
# mounts each requested transport (Basecamp projects and/or GitHub repos) as a
# route on it. Basecamp and GitHub watching therefore run simultaneously over a
# single funnel — the per-machine funnel is no longer a bottleneck.
class BasecampAgentConnector::Connector
  # Todo + Kanban::Step are included so todo/step assignment events are delivered
  # (Kanban::Card already covers card assignments).
  DEFAULT_TYPES = "Comment,Message,Kanban::Card,Kanban::Step,Todo"
  DEFAULT_EVENTS = "pull_request_review"

  Options = Data.define(:agent, :operator, :projects, :types, :watched_columns, :repos, :events, :port,
    :pings, :ping_interval, :state_path)

  def self.start(argv)
    new(parse_options(argv)).start
  rescue ArgumentError => error
    abort error.message
  end

  def self.parse_options(argv)
    arguments = argv.dup
    projects = []
    watched_columns = []
    repos = []
    operator = nil
    types = DEFAULT_TYPES
    events = DEFAULT_EVENTS
    port = nil
    pings = true
    ping_interval = BasecampAgentConnector::Basecamp::PingWatcher::DEFAULT_INTERVAL
    state_path = BasecampAgentConnector::PollState::DEFAULT_PATH

    OptionParser.new do |parser|
      parser.banner = "Usage: connect [@AGENT] [--project PROJECT]... [--watch-column BUCKET:COLUMN[:CREATOR]]... [--repo OWNER/REPO]... [--operator PROFILE] [--types TYPES] [--events EVENTS] [--port PORT] [--no-pings] [--ping-interval SECONDS] [--state PATH]"
      parser.on("--project PROJECT", "Basecamp project name, URL, or ID (repeatable)") { |value| projects << value }
      parser.on("--watch-column SPEC", "Trigger on any card created in this column, with no mention or assignment (repeatable)") do |value|
        watched_columns << BasecampAgentConnector::Basecamp::WatchedColumn.parse(value)
      end
      parser.on("--repo OWNER/REPO", "GitHub repo to watch for reviews (repeatable)") { |value| repos << value }
      parser.on("--operator PROFILE", "Profile whose user is allowed to trigger (default: CLI default profile)") { |value| operator = value }
      parser.on("--types TYPES", "Comma-separated Basecamp event types") { |value| types = value }
      parser.on("--events EVENTS", "Comma-separated GitHub webhook events") { |value| events = value }
      parser.on("--port PORT", Integer, "Local port for the webhook server") { |value| port = value }
      parser.on("--[no-]pings", "Trigger on the operator's Basecamp pings, polled (default: on)") { |value| pings = value }
      parser.on("--ping-interval SECONDS", Integer, "Seconds between ping rounds (default: #{BasecampAgentConnector::Basecamp::PingWatcher::DEFAULT_INTERVAL})") { |value| ping_interval = value }
      parser.on("--state PATH", "Where to remember handled pings (default: #{BasecampAgentConnector::PollState::DEFAULT_PATH})") { |value| state_path = value }
    end.parse!(arguments)

    agent = arguments.shift

    raise ArgumentError, "watch something: pass at least one --project or --repo" if projects.empty? && repos.empty?
    raise ArgumentError, "an agent is required to watch Basecamp projects, e.g. `connect @clawdito --project \"My Project\"`" if projects.any? && (agent.nil? || agent.empty?)

    warn_about_unwatched_buckets(watched_columns, projects)

    Options.new(agent: normalize_agent(agent), operator: operator, projects: projects, types: types,
      watched_columns: watched_columns, repos: repos, events: events_list(events), port: port,
      pings: pings, ping_interval: ping_interval, state_path: state_path)
  end

  # Webhooks are registered per project, so a watched column whose bucket is not
  # among them is silently dead — no delivery ever arrives to match it. Projects
  # can be named rather than numbered, so this can only warn.
  def self.warn_about_unwatched_buckets(watched_columns, projects)
    watched_columns.each do |watched|
      bucket = watched.bucket.to_s

      unless projects.any? { |project| project.to_s.include?(bucket) }
        warn "Warning: --watch-column #{watched} names bucket #{bucket}, which no --project argument mentions. " \
          "If that project is not watched, its card creations never arrive."
      end
    end
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

  def start
    @bridges = build_bridges
    port = @options.port || free_port

    @tunnel = BasecampAgentConnector::Tunnel.new(port: port, command_runner: command_runner)
    base_url = @tunnel.start
    @bridges.each { |bridge| bridge.register(base_url: base_url) }

    @server = BasecampAgentConnector::Server.new(port: port, routes: routes)
    install_signal_handlers
    @ping_watcher = start_ping_watcher
    @server.start
  ensure
    teardown
  end

  private
    def build_bridges
      bridges = []
      bridges << basecamp_bridge if @options.projects.any?
      bridges << github_bridge if @options.repos.any?
      bridges
    end

    def basecamp_bridge
      operator = resolve_operator
      agent = resolve_agent
      warn_if_same_user(agent, operator)

      BasecampAgentConnector::Basecamp::Bridge.new \
        operator: operator, agent: agent,
        projects: @options.projects, types: @options.types,
        watched_columns: @options.watched_columns,
        basecamp_cli: basecamp_cli, emitter: emitter
    end

    def github_bridge
      BasecampAgentConnector::GitHub::Bridge.new \
        repos: @options.repos, events: @options.events,
        github_cli: github_cli, emitter: emitter
    end

    def routes
      @bridges.to_h { |bridge| [ bridge.path, bridge.handler ] }
    end

    def resolve_agent
      BasecampAgentConnector::Basecamp::Identity.resolve(basecamp_cli: basecamp_cli, profile: @options.agent)
    rescue BasecampAgentConnector::Basecamp::Client::Error => error
      abort "No usable local Basecamp profile '#{@options.agent}'.\n" \
        "Run `basecamp auth login --profile #{@options.agent}` and log in as that user, then retry.\n(#{error.message})"
    end

    def resolve_operator
      BasecampAgentConnector::Basecamp::Identity.resolve(basecamp_cli: basecamp_cli, profile: @options.operator)
    rescue BasecampAgentConnector::Basecamp::Client::Error => error
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

    def install_signal_handlers
      %w[INT TERM].each do |signal|
        Signal.trap(signal) { @server.stop }
      end
    end

    def teardown
      @server&.stop
      @ping_watcher&.stop
      @bridges&.each(&:teardown)
      @tunnel&.stop
    end

    # Pings belong to no project, so they ride along with whatever else is being
    # watched rather than being asked for -- but they need the agent identity, and
    # a run watching only GitHub repos has none to resolve.
    def start_ping_watcher
      return nil unless @options.pings && @options.projects.any?

      state = BasecampAgentConnector::PollState.new(path: @options.state_path)
      agent = resolve_agent
      operator = resolve_operator

      BasecampAgentConnector::Basecamp::PingWatcher.new(
        pings: BasecampAgentConnector::Basecamp::Pings.new(
          basecamp_cli: basecamp_cli, agent: agent, operator: operator, state: state),
        pipeline: BasecampAgentConnector::Basecamp::Pipeline.new(
          operator: operator, agent: agent, emitter: emitter,
          verifier: BasecampAgentConnector::Basecamp::Verifier.new(
            basecamp_cli: basecamp_cli, agent: agent, operator: operator)),
        state: state, interval: @options.ping_interval).start
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
      @basecamp_cli ||= BasecampAgentConnector::Basecamp::Client.new(command_runner: command_runner)
    end

    def github_cli
      @github_cli ||= BasecampAgentConnector::GitHub::Client.new(command_runner: command_runner)
    end

    def emitter
      @emitter ||= BasecampAgentConnector::Emitter.new
    end
end
