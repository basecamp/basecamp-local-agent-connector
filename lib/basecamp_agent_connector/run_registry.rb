require "json"
require "fileutils"
require "open3"
require "time"

# Which connectors are running on this machine, and which funnel paths each one
# owns. Two failures made this necessary, both observed in practice:
#
# 1. Nothing stopped a second connector starting on the same agent and
#    projects. Both registered webhooks, both polled the same campfires, both
#    polled the same received-boosts feed — so one mention dispatched twice,
#    and the agent replied twice.
# 2. Nothing could tell a live connector's webhook from a leftover. A cleanup
#    that read unrecognized `/hook/<secret>` registrations as orphans deleted
#    eleven belonging to a *running* connector, leaving it deaf to Basecamp
#    while it went on polling chat, with no error anywhere to say so.
#
# So each run records one file naming its pid and the paths it owns, and
# removes it at teardown. Liveness is a pid probe, which makes a SIGKILLed
# run's file prunable rather than permanent — and a webhook whose path belongs
# to a pruned run is provably an orphan, the one case a sweep may delete
# without asking. An unrecognized path is never touched: it may be another
# machine's, another tool's, or an older build's, and none of those are ours
# to reap.
class BasecampAgentConnector::RunRegistry
  DEFAULT_DIRECTORY = File.expand_path("~/.config/basecamp-connect/runs")

  # The process start time. Recorded alongside the pid because a pid alone is
  # ambiguous once it is recycled, and reading a live run as dead is the
  # expensive direction: the sweep would delete its webhooks. Clock ticks since
  # boot from /proc/<pid>/stat field 22 where /proc exists (`comm` may itself
  # contain spaces and parens, so the fields are counted from the last ')');
  # `ps -o lstart=` elsewhere, darwin having no /proc.
  def self.process_start(pid)
    procfs? ? proc_start(pid) : ps_start(pid)
  end

  def self.procfs?
    File.exist?("/proc/self")
  end

  def self.proc_start(pid)
    stat = File.read("/proc/#{pid}/stat")
    stat[(stat.rindex(")") + 2)..].split[19]
  rescue SystemCallError, NoMethodError, TypeError
    nil
  end

  # `lstart` is rendered in the caller's locale and zone, and the value is
  # compared as text across processes that may not share them; pin both.
  def self.ps_start(pid)
    start, _stderr, status = Open3.capture3({ "LC_ALL" => "C", "TZ" => "UTC" }, "ps", "-o", "lstart=", "-p", pid.to_s)
    start.strip if status.success? && !start.strip.empty?
  rescue SystemCallError
    nil
  end

  Run = Data.define(:pid, :process_start, :started_at, :agent, :operator, :projects, :repos, :paths, :boosts) do
    def self.from_json(json)
      new(pid: json["pid"], process_start: json["process_start"], started_at: json["started_at"],
        agent: json["agent"], operator: json["operator"],
        projects: Array(json["projects"]), repos: Array(json["repos"]), paths: Array(json["paths"]),
        boosts: json["boosts"] != false)
    end

    def alive?
      Process.kill(0, pid)
      same_process?
    rescue Errno::ESRCH
      false
    rescue Errno::EPERM
      # Another user's process: alive enough that pruning it would be a lie.
      true
    end

    def description
      watching = [ projects.any? ? "#{projects.length} project(s)" : nil, repos.any? ? "#{repos.length} repo(s)" : nil ]
      "pid #{pid}, @#{agent}, #{watching.compact.join(" + ")}, started #{started_at}"
    end

    private
      # Only a recorded start time that disagrees with the live one proves the
      # pid was recycled. Either side missing (no /proc, an older entry) leaves
      # the bare pid probe as the answer, which errs toward "alive".
      def same_process?
        live = BasecampAgentConnector::RunRegistry.process_start(pid)
        process_start.nil? || live.nil? || process_start == live
      end
  end

  def initialize(directory: DEFAULT_DIRECTORY, logger: $stderr)
    @directory = directory
    @logger = logger
  end

  def live
    entries.map(&:last).select(&:alive?)
  end

  # Deletes the files of runs that are no longer running and returns those
  # runs, so the caller can reap what they left behind.
  def prune
    entries.filter_map do |file, run|
      next if run.alive?

      remove(file)
      run
    end
  end

  # Runs of the same agent that overlap on a watched project or repo: two of
  # those means every event arrives twice.
  def duplicates_of(agent:, projects:, repos:)
    same_agent(agent).select do |run|
      overlap?(run.projects, projects) || overlap?(run.repos, repos)
    end
  end

  # Same agent, no detected overlap. Still worth saying out loud: project
  # tokens are compared as written, so a name in one run and an id in the
  # other hides a real duplicate — and the received-boosts feed is per-agent,
  # so two boost pollers on one agent double every boost regardless of
  # projects.
  def same_agent_elsewhere(agent:, projects:, repos:)
    same_agent(agent) - duplicates_of(agent: agent, projects: projects, repos: repos)
  end

  def record(agent:, operator:, projects:, repos:, paths:, boosts:)
    FileUtils.mkdir_p @directory
    File.write file_for(Process.pid), JSON.generate(
      pid: Process.pid, process_start: self.class.process_start(Process.pid),
      started_at: Time.now.utc.iso8601, agent: agent, operator: operator,
      projects: projects, repos: repos, paths: paths, boosts: boosts)
  rescue SystemCallError => error
    # Bookkeeping must never take the connector down with it.
    log "could not record this run in #{@directory}: #{error.message}"
  end

  def forget
    remove file_for(Process.pid)
  end

  private
    def entries
      Dir.glob(File.join(@directory, "*.json")).filter_map { |file| read(file) }
    end

    def same_agent(agent)
      live.select { |run| run.agent == agent }
    end

    def overlap?(recorded, requested)
      (normalize(recorded) & normalize(requested)).any?
    end

    def normalize(tokens)
      Array(tokens).map { |token| token.to_s.strip.downcase }.reject(&:empty?)
    end

    def read(file)
      [ file, Run.from_json(JSON.parse(File.read(file))) ]
    rescue JSON::ParserError, SystemCallError, TypeError
      # An unreadable or half-written file says nothing; leaving it costs one
      # skipped entry, deleting it could drop a live run's paths.
      nil
    end

    def remove(file)
      File.delete file
    rescue SystemCallError
      nil
    end

    def file_for(pid)
      File.join(@directory, "#{pid}.json")
    end

    def log(message)
      @logger.puts message
    end
end
