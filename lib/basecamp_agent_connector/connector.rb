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
  # Chat::Line selects Campfire coverage: chat has no webhooks, so the Basecamp
  # bridge covers it with an integrated poller rather than a registration.
  DEFAULT_TYPES = "Comment,Message,Kanban::Card,Kanban::Step,Todo,Chat::Line"
  DEFAULT_EVENTS = "pull_request_review"
  TRUST_MODES = %w[operator allowlist project domain]

  Options = Data.define(:agent, :operator, :projects, :types, :repos, :events, :gh_operator, :port,
    :trust, :allowed_emails, :allowed_domains, :allow_assignments, :chat_poll, :boost_poll)

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
    gh_operator = nil
    types = DEFAULT_TYPES
    events = DEFAULT_EVENTS
    port = nil
    trust = nil
    allowed_emails = []
    allowed_domains = []
    allow_project = false
    allow_assignments = false
    chat_poll = BasecampAgentConnector::Basecamp::ChatPoller::DEFAULT_INTERVAL
    boost_poll = BasecampAgentConnector::Basecamp::BoostPoller::DEFAULT_INTERVAL

    OptionParser.new do |parser|
      parser.banner = "Usage: connect [@AGENT] [--project PROJECT]... [--repo OWNER/REPO]... [--operator PROFILE] [--gh-operator LOGIN] " \
        "[--trust MODE] [--allow EMAIL]... [--allow-domain DOMAIN]... [--allow-project] " \
        "[--allow-assignments-from-authorized] [--types TYPES] [--chat-poll SECONDS] [--boost-poll SECONDS] [--no-boosts] [--events EVENTS] [--port PORT]"
      parser.on("--project PROJECT", "Basecamp project name, URL, or ID (repeatable)") { |value| projects << value }
      parser.on("--repo OWNER/REPO", "GitHub repo to watch for reviews (repeatable)") { |value| repos << value }
      parser.on("--operator PROFILE", "Profile whose user is allowed to trigger (default: CLI default profile)") { |value| operator = value }
      parser.on("--gh-operator LOGIN", "GitHub login whose PR approvals are actionable (default: the login `gh` is authenticated as)") do |value|
        raise ArgumentError, "--gh-operator needs a GitHub login" if value.strip.empty?

        gh_operator = value.strip
      end
      parser.on("--trust MODE", TRUST_MODES, "Who may trigger the agent: #{TRUST_MODES.join(", ")} (default: operator only; " \
        "value flags below imply their mode)") do |value|
        raise ArgumentError, "--trust given twice with different modes (#{trust} then #{value})" if !trust.nil? && trust != value.to_sym

        trust = value.to_sym
      end
      parser.on("--allow EMAIL", "Also trust this author email (repeatable or comma-separated; implies --trust allowlist)") \
        { |value| allowed_emails.concat(comma_list(value)) }
      parser.on("--allow-domain DOMAIN", "Trust any author whose email is at this domain (repeatable or comma-separated; " \
        "implies --trust domain; --trust domain alone defaults to #{BasecampAgentConnector::Basecamp::Authorizer::DEFAULT_TRUSTED_DOMAIN})") \
        { |value| allowed_domains.concat(comma_list(value)) }
      parser.on("--allow-project", "Trust any corroborated non-client author of a recording the operator can read (implies --trust project)") { allow_project = true }
      parser.on("--allow-assignments-from-authorized", "Let any authorized author trigger via assignment too " \
        "(default: assignments are operator-only in every mode)") { allow_assignments = true }
      parser.on("--types TYPES", "Comma-separated Basecamp event types (Chat::Line = Campfire coverage, via polling)") { |value| types = value }
      parser.on("--chat-poll SECONDS", Integer, "Campfire poll interval " \
        "(default: #{BasecampAgentConnector::Basecamp::ChatPoller::DEFAULT_INTERVAL}s; chat has no webhooks)") do |value|
        raise ArgumentError, "--chat-poll must be a positive number of seconds" unless value.positive?

        chat_poll = value
      end
      parser.on("--boost-poll SECONDS", Integer, "Received-boosts poll interval " \
        "(default: #{BasecampAgentConnector::Basecamp::BoostPoller::DEFAULT_INTERVAL}s; boosts have no webhooks)") do |value|
        raise ArgumentError, "--boost-poll must be a positive number of seconds" unless value.positive?

        boost_poll = value
      end
      parser.on("--no-boosts", "Don't poll the agent's received-boosts feed") { boost_poll = nil }
      parser.on("--events EVENTS", "Comma-separated GitHub webhook events") { |value| events = value }
      parser.on("--port PORT", Integer, "Local port for the webhook server") { |value| port = value }
    end.parse!(arguments)

    agent = arguments.shift

    raise ArgumentError, "watch something: pass at least one --project or --repo" if projects.empty? && repos.empty?
    raise ArgumentError, "an agent is required to watch Basecamp projects, e.g. `connect @clawdito --project \"My Project\"`" if projects.any? && (agent.nil? || agent.empty?)
    raise ArgumentError, "--types has no event types to watch" if projects.any? && comma_list(types).empty?

    trust = resolve_trust(trust, emails: allowed_emails, domains: allowed_domains, project: allow_project)

    Options.new(agent: normalize_agent(agent), operator: operator, projects: projects, types: types, repos: repos, events: events_list(events),
      gh_operator: gh_operator, port: port,
      trust: trust, allowed_emails: allowed_emails, allowed_domains: allowed_domains, allow_assignments: allow_assignments,
      chat_poll: chat_poll, boost_poll: boost_poll)
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

    # Chat-only watching has no inbound paths, so it needs no funnel at all —
    # Tailscale isn't required unless something actually receives webhooks.
    paths = @bridges.filter_map(&:path)
    base_url = \
      if paths.any?
        @tunnel = BasecampAgentConnector::Tunnel.new(port: port, paths: paths, command_runner: command_runner)
        @tunnel.start
      end
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
        chat_poll_interval: @options.chat_poll, boost_poll_interval: @options.boost_poll,
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
        repos: @options.repos, events: @options.events, operator: resolve_github_operator,
        github_cli: github_cli, emitter: emitter
    end

    # A bridge without inbound webhooks (chat-only Basecamp coverage) has no
    # path and mounts nothing.
    def routes
      @bridges.filter_map { |bridge| [ bridge.path, bridge.handler ] unless bridge.path.nil? }.to_h
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

    # The operator's GitHub login gates PR approvals. This machine's `gh` is
    # the operator's, so its authenticated login is the default; `--gh-operator`
    # names another login without consulting `gh` at all.
    def resolve_github_operator
      @options.gh_operator || github_cli.authenticated_login
    rescue BasecampAgentConnector::GitHub::Client::Error => error
      abort "Could not resolve the operator's GitHub login: #{error.message}\nRun `gh auth login`, or pass --gh-operator LOGIN, and try again."
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
