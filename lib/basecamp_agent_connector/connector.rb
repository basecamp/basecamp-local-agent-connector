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
    :trust, :allowed_emails, :allowed_domains, :allow_assignments, :chat_poll, :boost_poll, :allow_duplicate)

  def self.start(argv)
    return print_status if argv.include?("--status")

    new(parse_options(argv)).start
  rescue ArgumentError => error
    abort error.message
  end

  # What is already running on this machine, and which funnel paths each run
  # owns. The one authoritative answer to "is this webhook a leftover?" — read
  # it before deleting any registration by hand.
  def self.print_status(registry: BasecampAgentConnector::RunRegistry.new, command_runner: BasecampAgentConnector::CommandRunner.new)
    registry.prune
    runs = registry.live

    if runs.empty?
      puts "No connector recorded as running on this machine."
    else
      puts "#{runs.length} connector(s) running on this machine:"
      runs.each do |run|
        puts "  #{run.description}"
        puts "    projects: #{run.projects.join(', ')}" if run.projects.any?
        puts "    repos:    #{run.repos.join(', ')}" if run.repos.any?
        puts "    paths:    #{run.paths.any? ? run.paths.join(', ') : "(none — chat-only, no webhooks)"}"
        puts "    boosts:   #{run.boosts ? "polling" : "off"}"
      end
      puts "A webhook whose payload_url ends in one of those paths belongs to a LIVE run. Don't delete it."
    end

    report_unrecorded_processes(runs, command_runner)
  end

  # The registry only knows runs that started with it. A connector launched by
  # an older build — or by another user — records nothing, so it would read as
  # "nothing running" while holding live webhooks nobody can attribute. That is
  # precisely how a running connector once lost eleven of its registrations to a
  # cleanup, so the process table gets consulted too and any pid the registry
  # doesn't cover is called out rather than passed over in silence.
  def self.report_unrecorded_processes(runs, command_runner)
    pids = running_connector_pids(command_runner) - runs.map(&:pid) - [ Process.pid ]
    return if pids.empty?

    puts
    puts "#{pids.length} connector process(es) running but NOT recorded: #{pids.join(', ')}."
    puts "Their funnel paths are unknown, so their webhooks cannot be attributed — do not delete a"
    puts "registration you cannot account for. Inspect with: ps -fp #{pids.join(',')}"
  end

  def self.running_connector_pids(command_runner)
    result = command_runner.run("pgrep", "-f", "bin/connect")
    result.stdout.split.map(&:to_i).reject(&:zero?).select { |pid| watching_process?(pid) }
  rescue SystemCallError, Errno::ENOENT
    []
  end

  # `pgrep -f` matches the whole command line, so it also catches the shell that
  # launched a connector (bin/connect buried inside its `-c` string) and this
  # very `--status` run. A real watcher has `bin/connect` as an argument of its
  # own and no `--status` among them. An unreadable cmdline errs toward
  # reporting: an unattributable connector is worth one false positive.
  def self.watching_process?(pid)
    arguments = File.read("/proc/#{pid}/cmdline").split("\u0000")
    arguments.any? { |argument| argument.end_with?("bin/connect") } && !arguments.include?("--status")
  rescue SystemCallError
    true
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
    allow_duplicate = false
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
        login = value.strip.delete_prefix("@")
        raise ArgumentError, "--gh-operator needs a GitHub login" if login.empty?

        gh_operator = login
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
      parser.on("--allow-duplicate", "Start even though another connector is already watching this agent " \
        "on these projects (default: refuse — every event would dispatch twice)") { allow_duplicate = true }
      parser.on("--status", "List the connectors running on this machine and the funnel paths they own, then exit") { }
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
      chat_poll: chat_poll, boost_poll: boost_poll, allow_duplicate: allow_duplicate)
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

  def initialize(options, registry: BasecampAgentConnector::RunRegistry.new)
    @options = options
    @registry = registry
  end

  def start
    refuse_duplicate_run
    warn_of_same_agent_elsewhere

    @bridges = build_bridges
    port = @options.port || free_port
    record_run

    # Chat-only watching has no inbound paths, so it needs no funnel at all —
    # Tailscale isn't required unless something actually receives webhooks.
    paths = @bridges.filter_map(&:path)
    base_url = \
      if paths.any?
        @tunnel = BasecampAgentConnector::Tunnel.new(port: port, paths: paths, command_runner: command_runner)
        @tunnel.start
      end
    # Runs that died without tearing down are pruned only now, once every
    # startup refusal is behind us: their files are the sole record of the
    # paths they owned, and registration is what sweeps those. Pruned any
    # earlier, a refused start would take that record with it and leave the
    # webhooks unattributable for good. Liveness, not the file, is what the
    # duplicate check reads, so a dead entry never refuses anyone.
    orphan_paths = @registry.prune.flat_map(&:paths)
    @bridges.each { |bridge| bridge.register(base_url: base_url, orphan_paths: orphan_paths) }

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
      refuse_same_user(agent, operator)

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

    # The agent's own identity never authorizes, so an operator who *is* the
    # agent can trigger nothing — and every corroborating fetch would run as
    # the agent. The usual way in is BASECAMP_PROFILE pinned to the agent's
    # profile with no --operator, since the CLI resolves an unflagged call
    # through that variable before the default profile.
    def refuse_same_user(agent, operator)
      if agent.same_user_as?(operator)
        abort "Agent '#{agent.profile}' and the operator#{operator_label} are the same Basecamp user (#{agent.email || agent.id}). " \
          "The agent's own identity never authorizes, so nothing could trigger. #{same_user_remedy}"
      end
    end

    def same_user_remedy
      pinned = ENV["BASECAMP_PROFILE"]
      if @options.operator.nil? && !pinned.to_s.empty?
        "BASECAMP_PROFILE=#{pinned} is set and --operator is not, so the operator — and every call made on the operator's " \
          "behalf — resolved through that profile. Unset it (env -u BASECAMP_PROFILE bin/connect …), " \
          "or pass --operator <your profile>, which pins those calls to that profile instead."
      else
        "Authenticate the agent profile as a distinct bot user, or pass --operator <your profile>."
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
      @registry.forget
    end

    # Two connectors on one agent and one project is never what anyone wanted:
    # both register a webhook per project, so Basecamp delivers every event to
    # both, and both poll the same campfires — one mention, two dispatched
    # agents, two replies. Refuse by default and name the other run, since the
    # symptom (duplicated work) is far harder to read than this message.
    def refuse_duplicate_run
      duplicates = @registry.duplicates_of(agent: @options.agent, projects: @options.projects, repos: @options.repos)
      return if duplicates.empty? || @options.allow_duplicate

      abort <<~MESSAGE
        Another connector is already watching @#{@options.agent} on something you asked for:
        #{duplicates.map { |run| "  #{run.description}" }.join("\n")}
        Every event would dispatch twice. Stop it first (kill #{duplicates.map(&:pid).join(" ")}), watch
        different projects, or pass --allow-duplicate if you really mean to run both.
        `bin/connect --status` lists every run and the funnel paths it owns.
      MESSAGE
    end

    # Same agent, no overlap detected. Not fatal, but worth saying: the
    # received-boosts feed is per-agent, so two boost pollers double every
    # boost whatever the projects — and project tokens are compared as
    # written, so a name here and an id there hides a real overlap.
    def warn_of_same_agent_elsewhere
      others = @registry.same_agent_elsewhere(agent: @options.agent, projects: @options.projects, repos: @options.repos)
      return if others.empty?

      warn "Warning: @#{@options.agent} is already being watched by #{others.map(&:description).join("; ")}. " \
        "No project overlap detected, but project names and ids don't compare, so check `bin/connect --status`."
      warn "Both runs poll the same received-boosts feed, so every boost dispatches twice — " \
        "pass --no-boosts to one of them." if @options.boost_poll && others.any?(&:boosts)
    end

    def record_run
      @registry.record agent: @options.agent, operator: @options.operator,
        projects: @options.projects, repos: @options.repos,
        paths: @bridges.flat_map(&:paths), boosts: !@options.boost_poll.nil?
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

    # Every call not made as the agent is made as the operator, so the
    # operator profile is the client's default: --operator then governs the
    # corroborating fetches and webhook registrations too, not just whose
    # identity authorizes, and a BASECAMP_PROFILE in the environment cannot
    # quietly substitute another principal for them.
    def basecamp_cli
      @basecamp_cli ||= BasecampAgentConnector::Basecamp::Client.new(command_runner: command_runner, profile: @options.operator)
    end

    def github_cli
      @github_cli ||= BasecampAgentConnector::GitHub::Client.new(command_runner: command_runner)
    end

    def emitter
      @emitter ||= BasecampAgentConnector::Emitter.new
    end
end
