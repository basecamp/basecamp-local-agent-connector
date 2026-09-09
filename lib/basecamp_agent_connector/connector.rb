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
  CORROBORATORS = %w[operator agent]

  Options = Data.define(:agent, :operator, :projects, :types, :repos, :events, :gh_operator, :port,
    :trust, :allowed_emails, :allowed_person_ids, :allowed_domains, :allow_assignments, :corroborate_as,
    :chat_poll, :boost_poll, :webhook_check, :allow_duplicate) do
    # The profile corroborating reads run under: nil is the CLI default (the
    # operator's own); `agent` names the agent's profile.
    def corroborating_profile
      agent if corroborate_as == :agent
    end
  end

  def self.start(argv)
    return print_status if argv.include?("--status")

    new(parse_options(argv)).start
  rescue ArgumentError => error
    abort error.message
  end

  # What is already running on this machine, and which funnel paths each run
  # owns. The one authoritative answer to "is this webhook a leftover?" — read
  # it before deleting any registration by hand.
  #
  # Strictly a read: a dead run's entry is the only record of the paths it
  # owns, and the startup that sweeps those webhooks is the one entitled to
  # discard it. Pruning here would leave that startup nothing to sweep with.
  def self.print_status(registry: BasecampAgentConnector::RunRegistry.new, command_runner: BasecampAgentConnector::CommandRunner.new)
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
        puts "    trust:    #{run.trust_description}"
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
    result.stdout.split.map(&:to_i).reject(&:zero?).select { |pid| watching_process?(pid, command_runner) }
  rescue SystemCallError, Errno::ENOENT
    []
  end

  # `pgrep -f` matches the whole command line, so it also catches the shell that
  # launched a connector (bin/connect buried inside its `-c` string) and this
  # very `--status` run. A real watcher has `bin/connect` as the executable or
  # as the script an interpreter was handed — before any flag, which is what
  # rules the shell's `-c` string out once `ps` has joined argv into one line —
  # and no `--status` among its arguments. An unreadable command line errs
  # toward reporting: an unattributable connector is worth one false positive.
  def self.watching_process?(pid, command_runner)
    arguments = process_arguments(pid, command_runner)
    arguments.nil? || \
      (arguments.take_while { |argument| !argument.start_with?("-") }.any? { |argument| argument.end_with?("bin/connect") } && \
        !arguments.include?("--status"))
  end

  # Exact argv from /proc where it exists; `ps` elsewhere (darwin has no
  # /proc), which hands back one space-joined line, split on whitespace.
  def self.process_arguments(pid, command_runner)
    if BasecampAgentConnector::RunRegistry.procfs?
      File.read("/proc/#{pid}/cmdline").split("\u0000")
    else
      result = command_runner.run("ps", "-o", "command=", "-p", pid.to_s)
      result.stdout.split if result.success?
    end
  rescue SystemCallError
    nil
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
    allowed_person_ids = []
    allowed_domains = []
    allow_project = false
    allow_assignments = false
    allow_duplicate = false
    corroborate_as = :operator
    chat_poll = BasecampAgentConnector::Basecamp::ChatPoller::DEFAULT_INTERVAL
    boost_poll = BasecampAgentConnector::Basecamp::BoostPoller::DEFAULT_INTERVAL
    webhook_check = BasecampAgentConnector::Basecamp::WebhookMonitor::DEFAULT_INTERVAL

    OptionParser.new do |parser|
      parser.banner = "Usage: connect [@AGENT] [--project PROJECT]... [--repo OWNER/REPO]... [--operator PROFILE] [--gh-operator LOGIN] " \
        "[--trust MODE] [--allow EMAIL]... [--allow-person ID]... [--allow-domain DOMAIN]... [--allow-project] " \
        "[--allow-assignments-from-authorized] [--corroborate-as operator|agent] [--types TYPES] [--chat-poll SECONDS] " \
        "[--boost-poll SECONDS] [--no-boosts] [--webhook-check SECONDS] [--events EVENTS] [--port PORT]"
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
      parser.on("--allow-person ID", "Also trust this author by account Person id (repeatable or comma-separated; implies --trust " \
        "allowlist; works from any corroborating profile, admin or not)") { |value| allowed_person_ids.concat(person_id_list(value)) }
      parser.on("--allow-domain DOMAIN", "Trust any author whose email is at this domain (repeatable or comma-separated; " \
        "implies --trust domain; --trust domain alone defaults to #{BasecampAgentConnector::Basecamp::Authorizer::DEFAULT_TRUSTED_DOMAIN})") \
        { |value| allowed_domains.concat(comma_list(value)) }
      parser.on("--allow-project", "Trust any corroborated non-client author of a recording the operator can read (implies --trust project)") { allow_project = true }
      parser.on("--allow-assignments-from-authorized", "Let any authorized author trigger via assignment too " \
        "(default: assignments are operator-only in every mode)") { allow_assignments = true }
      parser.on("--corroborate-as WHO", CORROBORATORS, "Whose profile re-fetches each event for corroboration: #{CORROBORATORS.join(", ")} " \
        "(default: operator; `agent` reads what the agent user can read, which masks colleagues' emails)") { |value| corroborate_as = value.to_sym }
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
      parser.on("--webhook-check SECONDS", Integer, "How often to re-check that each registered webhook is still active " \
        "and its funnel path still mounted, restoring either (default: " \
        "#{BasecampAgentConnector::Basecamp::WebhookMonitor::DEFAULT_INTERVAL}s; Basecamp deactivates a webhook after 10 failed deliveries)") do |value|
        raise ArgumentError, "--webhook-check must be a positive number of seconds" unless value.positive?

        webhook_check = value
      end
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

    trust = resolve_trust(trust, emails: allowed_emails, person_ids: allowed_person_ids, domains: allowed_domains, project: allow_project)
    warn_of_masked_emails(trust, corroborate_as: corroborate_as, emails: allowed_emails)

    Options.new(agent: normalize_agent(agent), operator: operator, projects: projects, types: types, repos: repos, events: events_list(events),
      gh_operator: gh_operator, port: port,
      trust: trust, allowed_emails: allowed_emails, allowed_person_ids: allowed_person_ids, allowed_domains: allowed_domains,
      allow_assignments: allow_assignments, corroborate_as: corroborate_as,
      chat_poll: chat_poll, boost_poll: boost_poll, webhook_check: webhook_check, allow_duplicate: allow_duplicate)
  end

  # `--trust MODE` picks the mode explicitly; otherwise the value flags imply
  # it (`--allow` / `--allow-person` => allowlist, `--allow-domain` => domain,
  # `--allow-project` => project) and no flags at all means operator-only.
  # Mixing flags that imply different modes, or a value flag contradicting
  # `--trust`, is refused rather than guessed at.
  def self.resolve_trust(explicit, emails:, domains:, project:, person_ids: [])
    implied = []
    implied << :allowlist if emails.any? || person_ids.any?
    implied << :domain if domains.any?
    implied << :project if project

    raise ArgumentError, "pick one trust mode: --allow/--allow-person, --allow-domain, and --allow-project imply different modes" if implied.length > 1
    raise ArgumentError, "--trust #{explicit} conflicts with --allow#{"-domain" if implied == [ :domain ]}#{"-project" if implied == [ :project ]}" \
      if !explicit.nil? && implied.any? && implied != [ explicit ]
    raise ArgumentError, "--trust allowlist needs at least one --allow EMAIL or --allow-person ID" if explicit == :allowlist && emails.empty? && person_ids.empty?

    explicit || implied.first || :operator
  end

  # The agent's profile is not an account admin, so a recording it re-fetches
  # shows every other author's email masked (`j••••@••••.•••`): an email-keyed
  # trust rule can never match under it. Say so at startup rather than let the
  # events drop in silence, which is how this failure otherwise presents.
  def self.warn_of_masked_emails(trust, corroborate_as:, emails:)
    return unless corroborate_as == :agent

    if trust == :domain
      warn "Warning: --corroborate-as agent masks authors' emails, so --trust domain can authorize nobody but the operator. " \
        "Use --allow-person for colleagues."
    elsif trust == :allowlist && emails.any?
      warn "Warning: --corroborate-as agent masks authors' emails, so the --allow email entries (#{emails.join(", ")}) can never match. " \
        "List those colleagues with --allow-person instead."
    end
  end

  def self.comma_list(value)
    value.split(",").map(&:strip).reject(&:empty?)
  end

  def self.person_id_list(value)
    comma_list(value).map do |token|
      raise ArgumentError, "--allow-person takes account Person ids (digits), not #{token.inspect}" unless token.match?(/\A\d+\z/)

      token.to_i
    end
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
    # Runs that died without tearing down are read first — and left on disk.
    # Their entries name the webhooks they abandoned, which the sweep below
    # needs, and which nothing else on this machine could attribute.
    abandoned = @registry.abandoned
    reserve_run

    @bridges = build_bridges
    port = @options.port || free_port
    record_run
    sweep_orphans abandoned

    # Chat-only watching has no inbound paths, so it needs no funnel at all —
    # Tailscale isn't required unless something actually receives webhooks.
    paths = @bridges.filter_map(&:path)
    base_url = \
      if paths.any?
        @tunnel = BasecampAgentConnector::Tunnel.new(port: port, paths: paths, command_runner: command_runner)
        @tunnel.start
      end
    @bridges.each { |bridge| bridge.register(base_url: base_url) }
    start_funnel_monitor if @tunnel

    @server = BasecampAgentConnector::Server.new(port: port, routes: routes)
    install_signal_handlers
    @server.start
  ensure
    teardown
  end

  private
    def build_bridges
      @basecamp_bridge = basecamp_bridge if @options.projects.any?
      @github_bridge = github_bridge if @options.repos.any?
      [ @basecamp_bridge, @github_bridge ].compact
    end

    # Reaps what the dead left behind, then forgets only the runs whose every
    # project and repo this startup could account for. A run watching projects
    # this one doesn't — or repos, when no GitHub bridge is built — keeps its
    # entry, because that entry is the sole record of whose those webhooks are.
    # Discarding it on the way past is what turned a dead run's registrations
    # into permanent litter.
    def sweep_orphans(abandoned)
      return if abandoned.empty?

      projects = @basecamp_bridge&.sweep_orphans(abandoned) || []
      repos = @github_bridge&.sweep_orphans(abandoned) || []
      @registry.discard abandoned.select { |run| run.swept_by?(projects: projects, repos: repos) }
    end

    def basecamp_bridge
      operator = resolve_operator
      agent = resolve_agent
      refuse_same_user(agent, operator)

      BasecampAgentConnector::Basecamp::Bridge.new \
        authorizer: authorizer(operator, agent), agent: agent,
        projects: @options.projects, types: @options.types,
        chat_poll_interval: @options.chat_poll, boost_poll_interval: @options.boost_poll,
        webhook_check_interval: @options.webhook_check,
        corroborate_as: @options.corroborating_profile, pairings: BasecampAgentConnector::Pairings.new,
        basecamp_cli: basecamp_cli, emitter: emitter
    end

    def authorizer(operator, agent)
      BasecampAgentConnector::Basecamp::Authorizer.build \
        trust: @options.trust, operator: operator, agent: agent,
        emails: @options.allowed_emails, person_ids: @options.allowed_person_ids, domains: @options.allowed_domains,
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
      @funnel_monitor&.stop
      @tunnel&.stop
      @registry.forget
    end

    # Two connectors on one agent and one project is never what anyone wanted:
    # both register a webhook per project, so Basecamp delivers every event to
    # both, and both poll the same campfires — one mention, two dispatched
    # agents, two replies. Refusing and claiming happen together in the
    # registry, so two connectors started in the same instant can't both pass
    # the check.
    def reserve_run
      warn_of_same_agent_elsewhere @registry.reserve(
        agent: @options.agent, operator: @options.operator,
        projects: @options.projects, repos: @options.repos,
        boosts: polling_boosts?, allow_duplicate: @options.allow_duplicate)
    rescue BasecampAgentConnector::RunRegistry::DuplicateRun => error
      abort duplicate_run_message(error.runs)
    rescue BasecampAgentConnector::RunRegistry::Error => error
      abort unrecordable_run_message(error)
    end

    def duplicate_run_message(duplicates)
      <<~MESSAGE
        Another connector is already watching #{@options.agent ? "@#{@options.agent}" : "one of these repos"}:
        #{duplicates.map { |run| "  #{run.description}" }.join("\n")}
        Every event would dispatch twice. Stop it first (kill #{duplicates.map(&:pid).join(" ")}), watch
        different projects, or pass --allow-duplicate if you really mean to run both.
        `bin/connect --status` lists every run and the funnel paths it owns.
      MESSAGE
    end

    # Nothing else provides what the record provides: without it the next
    # startup cannot see this run, and every webhook registered below becomes
    # a registration nobody can attribute — which is how eleven of them were
    # deleted from under a live connector. Refuse to start instead.
    def unrecordable_run_message(error)
      "Could not claim this run: #{error.message}\n" \
        "Starting anyway would leave webhooks nobody can attribute and duplicates nobody can detect. " \
        "Fix that directory and retry."
    end

    # Same agent, no overlap detected. Not fatal, but worth saying: the
    # received-boosts feed is per-agent, so two boost pollers double every
    # boost whatever the projects — and project tokens are compared as
    # written, so a name here and an id there hides a real overlap.
    def warn_of_same_agent_elsewhere(others)
      return if others.empty?

      warn "Warning: @#{@options.agent} is already being watched by #{others.map(&:description).join("; ")}. " \
        "No project overlap detected, but project names and ids don't compare, so check `bin/connect --status`."
      warn "Both runs poll the same received-boosts feed, so every boost dispatches twice — " \
        "pass --no-boosts to one of them." if @options.boost_poll && others.any?(&:boosts)
    end

    # Completes the reservation with the paths the bridges own, which is what
    # a later sweep needs to tell this run's webhooks from litter.
    def record_run
      @registry.record agent: @options.agent, operator: @options.operator,
        projects: @options.projects, repos: @options.repos,
        paths: @bridges.flat_map(&:paths), boosts: polling_boosts?,
        trust: trust_record
    rescue BasecampAgentConnector::RunRegistry::Error => error
      abort unrecordable_run_message(error)
    end

    # Only the Basecamp bridge polls boosts, and a GitHub-only run builds none
    # whatever --boost-poll says.
    def polling_boosts?
      @options.projects.any? && !@options.boost_poll.nil?
    end

    # Who this run trusts, so `--status` can say whether a person's request
    # could have come through this connector.
    def trust_record
      {
        "mode" => @options.trust.to_s,
        "emails" => @options.allowed_emails,
        "person_ids" => @options.allowed_person_ids,
        "domains" => trusted_domains,
        "corroborate_as" => @options.corroborate_as.to_s
      }
    end

    # Bare `--trust domain` admits the default domain without listing it.
    def trusted_domains
      if @options.trust == :domain && @options.allowed_domains.empty?
        [ BasecampAgentConnector::Basecamp::Authorizer::DEFAULT_TRUSTED_DOMAIN ]
      else
        @options.allowed_domains
      end
    end


    # Every transport's path rides the one funnel, so the funnel is kept
    # mounted here, on the webhook check's cadence, not per bridge.
    def start_funnel_monitor
      @funnel_monitor = BasecampAgentConnector::FunnelMonitor.new(tunnel: @tunnel, interval: @options.webhook_check)
      @funnel_monitor.start
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
