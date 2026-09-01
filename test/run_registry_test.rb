require "test_helper"
require "tmpdir"

class RunRegistryTest < Minitest::Test
  def test_records_and_lists_this_run
    in_registry do |registry|
      registry.record(**run_attributes)

      assert_equal [ Process.pid ], registry.live.map(&:pid)
      assert_equal [ "/bc5/mine" ], registry.live.first.paths
    end
  end

  def test_forgetting_removes_the_run
    in_registry do |registry|
      registry.record(**run_attributes)
      registry.forget

      assert_empty registry.live
    end
  end

  def test_a_run_whose_process_is_gone_is_not_live
    in_registry do |registry, directory|
      write_run directory, pid: dead_pid, agent: "clawdito"

      assert_empty registry.live
    end
  end

  # The SIGKILL case: no teardown ran, so the file and its paths are all that
  # says those webhooks were ever ours — which is why reading them does not
  # delete them.
  def test_abandoned_runs_are_reported_and_left_on_disk
    in_registry do |registry, directory|
      write_run directory, pid: dead_pid, agent: "clawdito", paths: [ "/bc5/orphan" ]
      registry.record(**run_attributes)

      abandoned = registry.abandoned

      assert_equal [ "/bc5/orphan" ], abandoned.flat_map(&:paths)
      assert_path_exists File.join(directory, "#{dead_pid}.json")
      assert_equal [ Process.pid ], registry.live.map(&:pid)
    end
  end

  def test_discarding_removes_the_entry_of_a_swept_run
    in_registry do |registry, directory|
      write_run directory, pid: dead_pid, agent: "clawdito", paths: [ "/bc5/orphan" ]

      registry.discard registry.abandoned

      refute_path_exists File.join(directory, "#{dead_pid}.json")
    end
  end

  # Scopes nothing swept keep the entry: the webhooks are still there, and the
  # entry is the only thing that could ever say they were ours.
  def test_a_run_is_swept_only_when_every_project_and_repo_it_watched_was
    run = BasecampAgentConnector::RunRegistry::Run.from_json(
      "pid" => dead_pid, "projects" => [ "Queenbee" ], "repos" => [ "basecamp/bc3" ], "paths" => [ "/bc5/orphan" ])

    assert run.swept_by?(projects: [ "Queenbee", "BC5.1" ], repos: [ "basecamp/bc3" ])
    refute run.swept_by?(projects: [ "Queenbee" ], repos: [])
    refute run.swept_by?(projects: [], repos: [ "basecamp/bc3" ])
  end

  # A pid is recyclable, and the gap between reading the abandoned runs and
  # discarding them spans a whole startup. Deleting by pathname would unclaim
  # the live connector that reserved under that pid in the meantime, and a
  # third startup would then reserve beside it.
  def test_discarding_leaves_the_entry_a_recycled_pid_has_since_reserved
    in_registry do |registry, directory|
      write_run directory, pid: Process.pid, agent: "clawdito", process_start: "0"
      abandoned = registry.abandoned

      registry.reserve(agent: "chef", operator: "jorge", projects: [ "Queenbee" ], repos: [], boosts: true)
      registry.discard abandoned

      assert_equal [ Process.pid ], registry.live.map(&:pid)
      assert_equal "chef", registry.live.first.agent
    end
  end

  def test_a_live_run_is_never_abandoned
    in_registry do |registry|
      registry.record(**run_attributes)

      assert_empty registry.abandoned
      assert_equal [ Process.pid ], registry.live.map(&:pid)
    end
  end

  def test_duplicates_need_the_same_agent_and_an_overlapping_project
    in_registry do |registry|
      registry.record(**run_attributes(agent: "clawdito", projects: [ "Queenbee", "On Call" ]))

      assert_equal [ Process.pid ], registry.duplicates_of(agent: "clawdito", projects: [ "on call" ], repos: []).map(&:pid)
      assert_empty registry.duplicates_of(agent: "clawdito", projects: [ "BC5.1" ], repos: [])
      assert_empty registry.duplicates_of(agent: "chef", projects: [ "Queenbee" ], repos: [])
    end
  end

  def test_an_overlapping_repo_is_a_duplicate_too
    in_registry do |registry|
      registry.record(**run_attributes(projects: [], repos: [ "basecamp/bc3" ]))

      assert_equal [ Process.pid ], registry.duplicates_of(agent: "clawdito", projects: [], repos: [ "basecamp/bc3" ]).map(&:pid)
    end
  end

  # A GitHub-only run has no agent, and the repo is what it would double up on.
  def test_two_agentless_runs_on_one_repo_are_still_duplicates
    in_registry do |registry|
      registry.record(**run_attributes(agent: nil, projects: [], repos: [ "basecamp/bc3" ]))

      assert_equal [ Process.pid ], registry.duplicates_of(agent: nil, projects: [], repos: [ "basecamp/bc3" ]).map(&:pid)
    end
  end

  def test_same_agent_elsewhere_reports_the_non_overlapping_run
    in_registry do |registry|
      registry.record(**run_attributes(agent: "clawdito", projects: [ "Queenbee" ]))

      assert_equal [ Process.pid ], registry.same_agent_elsewhere(agent: "clawdito", projects: [ "BC5.1" ], repos: []).map(&:pid)
      assert_empty registry.same_agent_elsewhere(agent: "clawdito", projects: [ "Queenbee" ], repos: [])
    end
  end

  # Two agentless runs share no agent, so there is nothing per-agent to double:
  # no mentions, no received-boosts feed.
  def test_an_agentless_run_is_never_the_same_agent_as_another
    in_registry do |registry|
      registry.record(**run_attributes(agent: nil, projects: [], repos: [ "basecamp/bc3" ]))

      assert_empty registry.same_agent_elsewhere(agent: nil, projects: [], repos: [ "acme/widgets" ])
    end
  end

  def test_reserving_records_the_run_with_no_paths_yet
    in_registry do |registry|
      elsewhere = registry.reserve(agent: "clawdito", operator: "jorge", projects: [ "Queenbee" ], repos: [], boosts: true)

      assert_empty elsewhere
      assert_equal [ Process.pid ], registry.live.map(&:pid)
      assert_empty registry.live.first.paths
      assert registry.live.first.boosts
    end
  end

  def test_reserving_beside_a_duplicate_refuses_and_records_nothing
    in_registry do |registry, directory|
      with_live_process do |pid|
        write_run directory, pid: pid, agent: "clawdito", projects: [ "Queenbee" ]

        error = assert_raises BasecampAgentConnector::RunRegistry::DuplicateRun do
          registry.reserve(agent: "clawdito", operator: "jorge", projects: [ "Queenbee" ], repos: [], boosts: true)
        end

        assert_equal [ pid ], error.runs.map(&:pid)
        refute_path_exists File.join(directory, "#{Process.pid}.json")
      end
    end
  end

  def test_reserving_with_allow_duplicate_records_anyway
    in_registry do |registry, directory|
      with_live_process do |pid|
        write_run directory, pid: pid, agent: "clawdito", projects: [ "Queenbee" ]

        registry.reserve(agent: "clawdito", operator: "jorge", projects: [ "Queenbee" ], repos: [], boosts: true, allow_duplicate: true)

        assert_includes registry.live.map(&:pid), Process.pid
      end
    end
  end

  def test_reserving_returns_the_same_agent_running_elsewhere
    in_registry do |registry, directory|
      with_live_process do |pid|
        write_run directory, pid: pid, agent: "clawdito", projects: [ "Queenbee" ]

        elsewhere = registry.reserve(agent: "clawdito", operator: "jorge", projects: [ "BC5.1" ], repos: [], boosts: true)

        assert_equal [ pid ], elsewhere.map(&:pid)
      end
    end
  end

  # The race the lock exists for. Checking and then recording as separate steps
  # lets every connector started in the same instant read an empty registry and
  # record, after which each one dispatches every event.
  def test_only_one_of_several_connectors_starting_together_reserves
    skip "fork is unavailable on this platform" unless Process.respond_to?(:fork)

    Dir.mktmpdir do |directory|
      outcomes = reserve_simultaneously(6, directory)

      assert_equal 1, outcomes.count("reserved"), "outcomes were #{outcomes.inspect}"
      assert_equal 5, outcomes.count("refused"), "outcomes were #{outcomes.inspect}"
    end
  end

  # Deleting a half-written file could drop a live run's paths, so it is
  # skipped rather than reaped.
  def test_an_unreadable_entry_is_skipped_not_deleted
    in_registry do |registry, directory|
      File.write File.join(directory, "999999.json"), "{not json"

      assert_empty registry.live
      assert_empty registry.abandoned
      assert_path_exists File.join(directory, "999999.json")
    end
  end

  # Recording is the whole guarantee: a run that isn't recorded can't be
  # detected as a duplicate and its webhooks can't be attributed, so the
  # failure has to reach the caller.
  def test_an_unwritable_directory_raises
    registry = BasecampAgentConnector::RunRegistry.new(directory: "/proc/nope/runs")

    assert_raises BasecampAgentConnector::RunRegistry::Error do
      registry.record(**run_attributes)
    end

    assert_raises BasecampAgentConnector::RunRegistry::Error do
      registry.reserve(agent: "clawdito", operator: "jorge", projects: [ "Queenbee" ], repos: [], boosts: true)
    end
  end

  # Entries name the funnel path the run owns, which is the secret that stands
  # between a forged payload and a dispatched agent.
  def test_entries_are_readable_only_by_their_owner
    in_new_directory do |registry, directory|
      with_permissive_umask { registry.record(**run_attributes) }

      assert_equal 0o700, mode_of(directory)
      assert_equal 0o600, mode_of(File.join(directory, "#{Process.pid}.json"))
      assert_equal [ "#{Process.pid}.json" ], Dir.children(directory)
    end
  end

  # mkdir_p leaves an existing directory's mode alone, so one an earlier build
  # created at 0755 would stay world-readable forever.
  def test_a_world_readable_directory_from_an_earlier_run_is_tightened
    in_new_directory do |registry, directory|
      FileUtils.mkdir directory
      File.chmod 0o755, directory

      registry.record(**run_attributes)

      assert_equal 0o700, mode_of(directory)
    end
  end

  private
    def in_registry
      Dir.mktmpdir do |directory|
        yield BasecampAgentConnector::RunRegistry.new(directory: directory), directory
      end
    end

    # A registry whose directory does not exist yet, so its creation is under
    # test too.
    def in_new_directory
      Dir.mktmpdir do |parent|
        directory = File.join(parent, "runs")
        yield BasecampAgentConnector::RunRegistry.new(directory: directory), directory
      end
    end

    def run_attributes(agent: "clawdito", projects: [ "Queenbee" ], repos: [], paths: [ "/bc5/mine" ], boosts: true)
      { agent: agent, operator: "jorge", projects: projects, repos: repos, paths: paths, boosts: boosts }
    end

    # `process_start` disagreeing with the live one is what proves a pid was
    # recycled; omitting it leaves the bare pid probe as the answer.
    def write_run(directory, pid:, agent:, projects: [ "Queenbee" ], repos: [], paths: [], process_start: nil)
      File.write File.join(directory, "#{pid}.json"), JSON.generate(
        pid: pid, process_start: process_start, started_at: "2026-09-01T00:00:00Z", agent: agent, operator: "jorge",
        projects: projects, repos: repos, paths: paths, boosts: true)
    end

    # A pid that is genuinely alive and genuinely not this process: the only
    # honest stand-in for another connector.
    def with_live_process
      pid = fork { sleep }
      yield pid
    ensure
      terminate pid
    end

    # Every child blocks on the same pipe until the parent closes it, so they
    # reach the registry together rather than in sequence. Each one stays alive
    # after reserving, or the others' liveness probe would find nothing.
    def reserve_simultaneously(children, directory)
      gate_read, gate_write = IO.pipe
      outcome_read, outcome_write = IO.pipe

      pids = Array.new(children) do
        fork do
          gate_write.close
          outcome_read.close
          gate_read.read
          outcome_write.puts reserve_outcome(directory)
          outcome_write.flush
          sleep
        end
      end

      gate_read.close
      outcome_write.close
      gate_write.close

      Array.new(children) { outcome_read.gets.to_s.strip }
    ensure
      pids&.each { |pid| terminate pid }
    end

    def reserve_outcome(directory)
      BasecampAgentConnector::RunRegistry.new(directory: directory)
        .reserve(agent: "clawdito", operator: "jorge", projects: [ "Queenbee" ], repos: [], boosts: true)
      "reserved"
    rescue BasecampAgentConnector::RunRegistry::DuplicateRun
      "refused"
    rescue => error
      "failed: #{error.message}"
    end

    def terminate(pid)
      Process.kill "KILL", pid
      Process.wait pid
    rescue Errno::ESRCH, Errno::ECHILD
      nil
    end

    def with_permissive_umask
      original = File.umask(0o000)
      yield
    ensure
      File.umask original
    end

    def mode_of(path)
      File.stat(path).mode & 0o777
    end

    # A pid nothing can be running under: the kernel's max is well below this.
    def dead_pid
      4_194_303
    end
end
