require "json"
require "fileutils"
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

  # An entry names the funnel path its run owns, and that path is the shared
  # secret standing between a forged payload and a dispatched agent. No other
  # local user has any business reading one.
  DIRECTORY_MODE = 0o700
  ENTRY_MODE = 0o600

  # The registry is the duplicate and ownership guarantee: a run that cannot be
  # recorded has neither, so the failure is raised rather than logged.
  class Error < StandardError; end

  # Another live run of this agent already covers one of these projects or
  # repos, so `reserve` recorded nothing.
  class DuplicateRun < Error
    attr_reader :runs

    def initialize(runs)
      @runs = runs
      super("another connector is already running: #{runs.map(&:description).join("; ")}")
    end
  end

  # The process start time, in clock ticks since boot, from /proc/<pid>/stat
  # field 22. Recorded alongside the pid because a pid alone is ambiguous once
  # it is recycled, and reading a live run as dead is the expensive direction:
  # the sweep would delete its webhooks. `comm` may itself contain spaces and
  # parens, so the fields are counted from the last ')'.
  def self.process_start(pid)
    stat = File.read("/proc/#{pid}/stat")
    stat[(stat.rindex(")") + 2)..].split[19]
  rescue SystemCallError, NoMethodError, TypeError
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
      [ "pid #{pid}", agent.nil? ? nil : "@#{agent}", watching.compact.join(" + "), "started #{started_at}" ].compact.join(", ")
    end

    # Every project and repo this run watched has been accounted for, so its
    # entry has no work left to do. Anything it watched that nothing swept
    # keeps the entry alive: the entry is the only thing that could ever
    # attribute a webhook still sitting there.
    def swept_by?(projects:, repos:)
      (self.projects - projects).empty? && (self.repos - repos).empty?
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

  def initialize(directory: DEFAULT_DIRECTORY)
    @directory = directory
  end

  def live
    entries.map(&:last).select(&:alive?)
  end

  # Runs that are no longer running, left exactly where they are. Their
  # entries name the webhooks they abandoned, and until something has swept
  # those, deleting the entry destroys the only record that they were ever
  # ours — which is how eleven registrations became unattributable litter.
  def abandoned
    entries.map(&:last).reject(&:alive?)
  end

  # Forgets abandoned runs whose webhooks have been reaped. Under the lock,
  # and only where the file still holds that exact run: pids are recycled, so
  # between the scan and here a new connector may have reserved under the same
  # pid, and deleting that entry would unclaim a live connector — after which
  # a third startup would happily reserve beside it.
  def discard(runs)
    return if runs.empty?

    exclusively do
      runs.each do |run|
        file = file_for(run.pid)
        remove file if read(file)&.last == run
      end
    end
  end

  # Refusing a duplicate and claiming this run are one indivisible step, under
  # a lock no other process on this machine can hold at the same time. Checking
  # and then recording separately is a race two connectors started together
  # lose together: both read an empty registry, both record, and every event
  # dispatches twice — the exact failure the registry exists to prevent.
  #
  # The paths are filled in by a later `record`, once the bridges that own them
  # have been built; holding the lock across that would serialize every startup
  # behind whatever a Basecamp identity lookup costs today.
  #
  # Returns the live runs of this agent that don't overlap: worth a warning,
  # not a refusal.
  def reserve(agent:, operator:, projects:, repos:, boosts:, allow_duplicate: false)
    exclusively do
      duplicates = duplicates_of(agent: agent, projects: projects, repos: repos)
      raise DuplicateRun, duplicates unless duplicates.empty? || allow_duplicate

      elsewhere = same_agent_elsewhere(agent: agent, projects: projects, repos: repos)
      record agent: agent, operator: operator, projects: projects, repos: repos, paths: [], boosts: boosts
      elsewhere
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
  #
  # A GitHub-only run has no agent, and two of those share nothing per-agent:
  # no boost feed, no mentions. Neither is "the same agent" as the other.
  def same_agent_elsewhere(agent:, projects:, repos:)
    return [] if agent.nil?

    same_agent(agent) - duplicates_of(agent: agent, projects: projects, repos: repos)
  end

  def record(agent:, operator:, projects:, repos:, paths:, boosts:)
    write file_for(Process.pid), JSON.generate(
      pid: Process.pid, process_start: self.class.process_start(Process.pid),
      started_at: started_at, agent: agent, operator: operator,
      projects: projects, repos: repos, paths: paths, boosts: boosts)
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

    # Reserving takes the lock; recording the paths afterwards rewrites this
    # run's own file, which no other process writes.
    def exclusively
      prepare_directory
      File.open(lock_file, File::RDWR | File::CREAT, ENTRY_MODE) do |lock|
        lock.flock File::LOCK_EX

        begin
          yield
        ensure
          lock.flock File::LOCK_UN
        end
      end
    rescue SystemCallError => error
      raise Error, "could not lock the run registry in #{@directory}: #{error.message}"
    end

    # Written to a neighbouring temporary file and renamed into place: a
    # concurrent reader sees the old entry or the new one, never half of one.
    # The mode is set at creation rather than left to the umask, which on most
    # machines would publish the funnel path to every local user.
    def write(file, contents)
      temporary = "#{file}.#{Process.pid}.tmp"
      prepare_directory
      File.open(temporary, File::WRONLY | File::CREAT | File::TRUNC, ENTRY_MODE) { |entry| entry.write contents }
      File.rename temporary, file
    rescue SystemCallError => error
      remove temporary
      raise Error, "could not record this run in #{@directory}: #{error.message}"
    end

    # An existing directory keeps whatever mode it was created with, which for
    # anything an earlier build made is 0755.
    def prepare_directory
      FileUtils.mkdir_p @directory, mode: DIRECTORY_MODE
      File.chmod DIRECTORY_MODE, @directory
    end

    def remove(file)
      File.delete file
    rescue SystemCallError
      nil
    end

    def file_for(pid)
      File.join(@directory, "#{pid}.json")
    end

    def lock_file
      File.join(@directory, ".lock")
    end

    # The reservation and the later paths write are the same run, so the
    # recorded start time is the first one.
    def started_at
      @started_at ||= Time.now.utc.iso8601
    end
end
