require "optparse"

# The entry point for polling mode. Same trust model, same emitted stream, and
# the same Pipeline as `connect` — only the transport differs. Nothing public is
# opened and no webhook is registered, so there is also nothing to tear down: a
# poll run that is killed uncleanly leaves no trace on Basecamp.
class BasecampAgentConnector::PollRunner
  DEFAULT_INTERVAL = 60

  MINIMUM_INTERVAL = 15

  Options = Data.define(:agent, :operator, :projects, :watched_columns, :interval, :backfill, :state_path, :pings)

  def self.start(argv)
    new(parse_options(argv)).start
  rescue ArgumentError => error
    abort error.message
  end

  def self.parse_options(argv)
    arguments = argv.dup
    projects = []
    watched_columns = []
    operator = nil
    interval = DEFAULT_INTERVAL
    backfill = false
    pings = true
    state_path = BasecampAgentConnector::PollState::DEFAULT_PATH

    OptionParser.new do |parser|
      parser.banner = "Usage: poll [@AGENT] [--project PROJECT]... [--watch-column BUCKET:COLUMN[:CREATOR]]... [--operator PROFILE] [--interval SECONDS] [--backfill] [--no-pings] [--state PATH]"
      parser.on("--project PROJECT", "Basecamp project id or name to accept events from (repeatable)") { |value| projects << value }
      parser.on("--watch-column SPEC", "Trigger on any card created in this column, with no mention or assignment (repeatable)") do |value|
        watched_columns << BasecampAgentConnector::Basecamp::WatchedColumn.parse(value)
      end
      parser.on("--operator PROFILE", "Profile whose user is allowed to trigger (default: CLI default profile)") { |value| operator = value }
      parser.on("--interval SECONDS", Integer, "Seconds between rounds (default: #{DEFAULT_INTERVAL})") { |value| interval = value }
      parser.on("--backfill", "Emit what is already waiting instead of starting from now") { backfill = true }
      parser.on("--[no-]pings", "Trigger on the operator's Basecamp pings (default: on)") { |value| pings = value }
      parser.on("--state PATH", "Where to remember handled events (default: #{BasecampAgentConnector::PollState::DEFAULT_PATH})") { |value| state_path = value }
    end.parse!(arguments)

    agent = arguments.shift

    raise ArgumentError, "an agent is required, e.g. `poll @clawdito --project \"My Project\"`" if agent.nil? || agent.empty?
    raise ArgumentError, "--interval below #{MINIMUM_INTERVAL}s hammers the API for no gain" if interval < MINIMUM_INTERVAL

    Options.new(agent: normalize_agent(agent), operator: operator, projects: projects,
      watched_columns: watched_columns, interval: interval, backfill: backfill, state_path: state_path,
      pings: pings)
  end

  def self.normalize_agent(agent)
    agent.sub(/\A@/, "").downcase
  end

  def initialize(options)
    @options = options
    @running = true
  end

  def start
    announce
    seed_unless_backfilling
    install_signal_handlers

    while @running
      poll
      wait
    end
  ensure
    state.save
  end

  private
    # A payload that cannot be corroborated because Basecamp could not be read is
    # not a payload that was handled. Give back what was remembered on its behalf
    # and let the next round find it again, rather than recording a blip as work
    # done and losing one of Fernando's cards to it.
    def poll
      sources.each { |source| drain source }
      state.save
    rescue StandardError => error
      warn "poll round failed: #{error.message}"
    end

    def drain(source)
      source.payloads.each do |payload|
        pipeline.process(payload)
      rescue BasecampAgentConnector::Basecamp::Verifier::Unreachable => error
        source.rollback payload
        warn "#{error.message} - will retry next round"
      end
    end

    # Two ways of noticing, sharing one state file and one pipeline. Poller reads
    # the surfaces a project has; Pings reads the conversations the operator has
    # opened with the agent, which belong to no project and are invisible to every
    # listing a project offers.
    def sources
      @sources ||= @options.pings ? [ poller, pings ] : [ poller ]
    end

    # Slept in slices so a signal lands within a second rather than at the end of
    # the interval.
    def wait
      @options.interval.times do
        break unless @running
        sleep 1
      end
    end

    # A first run starts from now. The alternative — treating everything already
    # waiting as new — would dispatch an agent per unread notification, and the
    # bot's inbox holds every mention since it was created.
    def seed_unless_backfilling
      return unless state.empty?

      if @options.backfill
        warn "Backfilling: everything currently waiting will be emitted."
      else
        sources.each(&:seed)
        state.save
        warn "Starting from now. Pass --backfill to pick up what is already waiting."
      end
    end

    def announce
      warn "Polling as #{agent.name} (#{agent.profile}) every #{@options.interval}s, " \
        "operator #{operator.email}#{watched_column_label}#{ping_label}. No funnel, no webhooks."
    end

    def ping_label
      @options.pings ? ", and his pings" : ""
    end

    def watched_column_label
      return "" if @options.watched_columns.empty?

      ", watching column#{'s' if @options.watched_columns.length > 1} #{@options.watched_columns.join(', ')}"
    end

    def install_signal_handlers
      %w[INT TERM].each do |signal|
        Signal.trap(signal) { @running = false }
      end
    end

    def poller
      @poller ||= BasecampAgentConnector::Basecamp::Poller.new \
        basecamp_cli: basecamp_cli, agent: agent, state: state,
        watched_columns: @options.watched_columns, projects: watched_project_identifiers
    end

    # A project can be given by id or by name, and the two listings disagree about
    # which one they report: a notification names its project and never numbers it,
    # while a card numbers its bucket. Resolving each argument to both means the
    # filter matches whichever the listing happens to carry.
    def watched_project_identifiers
      @watched_project_identifiers ||= @options.projects.flat_map do |project|
        resolved = basecamp_cli.project(project)
        [ resolved["id"].to_s, resolved["name"] ].compact
      rescue BasecampAgentConnector::Basecamp::Client::Error
        abort "Could not resolve --project #{project}. Pass the id or the exact name of a project the agent belongs to."
      end
    end

    def pipeline
      @pipeline ||= BasecampAgentConnector::Basecamp::Pipeline.new \
        operator: operator, agent: agent, verifier: verifier,
        emitter: BasecampAgentConnector::Emitter.new, watched_columns: @options.watched_columns
    end

    def pings
      @pings ||= BasecampAgentConnector::Basecamp::Pings.new \
        basecamp_cli: basecamp_cli, agent: agent, operator: operator, state: state
    end

    def verifier
      BasecampAgentConnector::Basecamp::Verifier.new(basecamp_cli: basecamp_cli, agent: agent, operator: operator)
    end

    def state
      @state ||= BasecampAgentConnector::PollState.new(path: @options.state_path)
    end

    def agent
      @agent ||= resolve(@options.agent) do
        abort "No usable local Basecamp profile '#{@options.agent}'.\n" \
          "Run `basecamp auth login --profile #{@options.agent}` and log in as that user, then retry."
      end
    end

    def operator
      @operator ||= resolve(@options.operator) do
        abort "Could not resolve the operator identity. Run `basecamp auth login` and try again."
      end
    end

    def resolve(profile)
      BasecampAgentConnector::Basecamp::Identity.resolve(basecamp_cli: basecamp_cli, profile: profile)
    rescue BasecampAgentConnector::Basecamp::Client::Error
      yield
    end

    def basecamp_cli
      @basecamp_cli ||= BasecampAgentConnector::Basecamp::Client.new
    end
end
