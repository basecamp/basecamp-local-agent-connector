require "optparse"
require "socket"

# The unified entry point. Opens ONE local server and mounts each requested
# transport (Basecamp projects and/or GitHub repos) as a route on it, exposing
# each route as its own path on this host's Tailscale Funnel. Basecamp and GitHub
# watching therefore run simultaneously — the per-machine funnel is no longer a
# bottleneck, and paths other tools mounted are left alone.
class BasecampAgentConnector::Connector
  # Todo + Kanban::Step are included so todo/step assignment events are delivered
  # (Kanban::Card already covers card assignments).
  DEFAULT_TYPES = "Comment,Message,Kanban::Card,Kanban::Step,Todo"
  DEFAULT_EVENTS = "pull_request_review"
  TRUST_MODES = %w[operator allowlist project domain]

  Options = Data.define(:agent, :operator, :projects, :types, :repos, :events, :port,
    :trust, :allowed_emails, :allowed_domains, :allow_assignments)

  def self.start(argv)
    new(parse_options(argv)).start
  rescue ArgumentError => error
    abort error.message
  end

  def self.parse_options(argv)
    arguments = argv.dup
    projects = []
    repos = []
    operator = nil
    types = DEFAULT_TYPES
    events = DEFAULT_EVENTS
    port = nil
    trust = nil
    allowed_emails = []
    allowed_domains = []
    allow_project = false
    allow_assignments = false

    OptionParser.new do |parser|
      parser.banner = "Usage: connect [@AGENT] [--project PROJECT]... [--repo OWNER/REPO]... [--operator PROFILE] " \
        "[--trust MODE] [--allow EMAIL]... [--allow-domain DOMAIN]... [--allow-project] " \
        "[--allow-assignments-from-authorized] [--types TYPES] [--events EVENTS] [--port PORT]"
      parser.on("--project PROJECT", "Basecamp project name, URL, or ID (repeatable)") { |value| projects << value }
      parser.on("--repo OWNER/REPO", "GitHub repo to watch for reviews (repeatable)") { |value| repos << value }
      parser.on("--operator PROFILE", "Profile whose user is allowed to trigger (default: CLI default profile)") { |value| operator = value }
      parser.on("--trust MODE", TRUST_MODES, "Who may trigger the agent: #{TRUST_MODES.join(", ")} (default: operator only; " \
        "value flags below imply their mode)") { |value| trust = value.to_sym }
      parser.on("--allow EMAIL", "Also trust this author email (repeatable or comma-separated; implies --trust allowlist)") \
        { |value| allowed_emails.concat(comma_list(value)) }
      parser.on("--allow-domain DOMAIN", "Trust any author whose email is at this domain (repeatable or comma-separated; " \
        "implies --trust domain; --trust domain alone defaults to #{BasecampAgentConnector::Basecamp::Authorizer::DEFAULT_TRUSTED_DOMAIN})") \
        { |value| allowed_domains.concat(comma_list(value)) }
      parser.on("--allow-project", "Trust any corroborated non-client author of a recording the operator can read (implies --trust project)") { allow_project = true }
      parser.on("--allow-assignments-from-authorized", "Let any authorized author trigger via assignment too " \
        "(default: assignments are operator-only in every mode)") { allow_assignments = true }
      parser.on("--types TYPES", "Comma-separated Basecamp event types") { |value| types = value }
      parser.on("--events EVENTS", "Comma-separated GitHub webhook events") { |value| events = value }
      parser.on("--port PORT", Integer, "Local port for the webhook server") { |value| port = value }
    end.parse!(arguments)

    agent = arguments.shift

    raise ArgumentError, "watch something: pass at least one --project or --repo" if projects.empty? && repos.empty?
    raise ArgumentError, "an agent is required to watch Basecamp projects, e.g. `connect @clawdito --project \"My Project\"`" if projects.any? && (agent.nil? || agent.empty?)

    trust = resolve_trust(trust, emails: allowed_emails, domains: allowed_domains, project: allow_project)

    Options.new(agent: normalize_agent(agent), operator: operator, projects: projects, types: types, repos: repos, events: events_list(events), port: port,
      trust: trust, allowed_emails: allowed_emails, allowed_domains: allowed_domains, allow_assignments: allow_assignments)
  end

  # `--trust MODE` picks the mode explicitly; otherwise the value flags imply
  # it (`--allow` => allowlist, `--allow-domain` => domain, `--allow-project`
  # => project) and no flags at all means operator-only. Mixing flags that
  # imply different modes, or a value flag contradicting `--trust`, is refused
  # rather than guessed at.
  def self.resolve_trust(explicit, emails:, domains:, project:)
    implied = []
    implied << :allowlist if emails.any?
    implied << :domain if domains.any?
    implied << :project if project

    raise ArgumentError, "pick one trust mode: --allow, --allow-domain, and --allow-project imply different modes" if implied.length > 1
    raise ArgumentError, "--trust #{explicit} conflicts with --allow#{"-domain" if implied == [ :domain ]}#{"-project" if implied == [ :project ]}" \
      if !explicit.nil? && implied.any? && implied != [ explicit ]
    raise ArgumentError, "--trust allowlist needs at least one --allow EMAIL" if explicit == :allowlist && emails.empty?

    explicit || implied.first || :operator
  end

  def self.comma_list(value)
    value.split(",").map(&:strip).reject(&:empty?)
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

    @tunnel = BasecampAgentConnector::Tunnel.new(port: port, paths: @bridges.map(&:path), command_runner: command_runner)
    base_url = @tunnel.start
    @bridges.each { |bridge| bridge.register(base_url: base_url) }

    @server = BasecampAgentConnector::Server.new(port: port, routes: routes)
    install_signal_handlers
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
        authorizer: authorizer(operator, agent), agent: agent,
        projects: @options.projects, types: @options.types,
        basecamp_cli: basecamp_cli, emitter: emitter
    end

    def authorizer(operator, agent)
      BasecampAgentConnector::Basecamp::Authorizer.build \
        trust: @options.trust, operator: operator, agent: agent,
        emails: @options.allowed_emails, domains: @options.allowed_domains,
        allow_assignments: @options.allow_assignments
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
          "The agent's own identity never authorizes, so nothing will trigger — authenticate the agent profile as a distinct bot user."
      end
    end

    def install_signal_handlers
      %w[INT TERM].each do |signal|
        Signal.trap(signal) { @server.stop }
      end
    end

    def teardown
      @server&.stop
      @bridges&.each(&:teardown)
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
      @basecamp_cli ||= BasecampAgentConnector::Basecamp::Client.new(command_runner: command_runner)
    end

    def github_cli
      @github_cli ||= BasecampAgentConnector::GitHub::Client.new(command_runner: command_runner)
    end

    def emitter
      @emitter ||= BasecampAgentConnector::Emitter.new
    end
end
