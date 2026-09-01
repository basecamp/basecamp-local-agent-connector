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
  # says those webhooks were ever ours.
  def test_pruning_removes_dead_runs_and_returns_what_they_owned
    in_registry do |registry, directory|
      write_run directory, pid: dead_pid, agent: "clawdito", paths: [ "/bc5/orphan" ]
      registry.record(**run_attributes)

      pruned = registry.prune

      assert_equal [ "/bc5/orphan" ], pruned.flat_map(&:paths)
      assert_equal [ Process.pid ], registry.live.map(&:pid)
      assert_equal 1, Dir.glob(File.join(directory, "*.json")).length
    end
  end

  def test_a_live_run_is_never_pruned
    in_registry do |registry|
      registry.record(**run_attributes)

      assert_empty registry.prune
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

  def test_same_agent_elsewhere_reports_the_non_overlapping_run
    in_registry do |registry|
      registry.record(**run_attributes(agent: "clawdito", projects: [ "Queenbee" ]))

      assert_equal [ Process.pid ], registry.same_agent_elsewhere(agent: "clawdito", projects: [ "BC5.1" ], repos: []).map(&:pid)
      assert_empty registry.same_agent_elsewhere(agent: "clawdito", projects: [ "Queenbee" ], repos: [])
    end
  end

  # Deleting a half-written file could drop a live run's paths, so it is
  # skipped rather than reaped.
  def test_an_unreadable_entry_is_skipped_not_deleted
    in_registry do |registry, directory|
      File.write File.join(directory, "999999.json"), "{not json"

      assert_empty registry.live
      assert_empty registry.prune
      assert_path_exists File.join(directory, "999999.json")
    end
  end

  def test_an_unwritable_directory_does_not_raise
    logs = StringIO.new
    registry = BasecampAgentConnector::RunRegistry.new(directory: "/proc/nope/runs", logger: logs)

    registry.record(**run_attributes)

    assert_match(/could not record this run/, logs.string)
  end

  private
    def in_registry
      Dir.mktmpdir do |directory|
        yield BasecampAgentConnector::RunRegistry.new(directory: directory, logger: StringIO.new), directory
      end
    end

    def run_attributes(agent: "clawdito", projects: [ "Queenbee" ], repos: [], paths: [ "/bc5/mine" ], boosts: true)
      { agent: agent, operator: "jorge", projects: projects, repos: repos, paths: paths, boosts: boosts }
    end

    def write_run(directory, pid:, agent:, paths: [])
      File.write File.join(directory, "#{pid}.json"), JSON.generate(
        pid: pid, started_at: "2026-09-01T00:00:00Z", agent: agent, operator: "jorge",
        projects: [ "Queenbee" ], repos: [], paths: paths, boosts: true)
    end

    # A pid nothing can be running under: the kernel's max is well below this.
    def dead_pid
      4_194_303
    end
end
