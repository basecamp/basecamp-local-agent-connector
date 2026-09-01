require "test_helper"
require "tmpdir"

class ConnectorTest < Minitest::Test
  def test_parses_basecamp_only_with_defaults
    options = BasecampAgentConnector::Connector.parse_options([ "@Clawdito", "--project", "Queenbee" ])

    assert_equal "clawdito", options.agent
    assert_equal [ "Queenbee" ], options.projects
    assert_empty options.repos
    assert_equal "Comment,Message,Kanban::Card,Kanban::Step,Todo,Chat::Line", options.types
    assert_equal [ "pull_request_review" ], options.events
    assert_nil options.port
    assert_equal :operator, options.trust
    assert_empty options.allowed_emails
    assert_empty options.allowed_domains
    refute options.allow_assignments
  end

  def test_allow_implies_allowlist_trust
    options = parse "@clawdito", "--project", "A", "--allow", "marie@example.com", "--allow", "sam@example.com, ana@example.com"

    assert_equal :allowlist, options.trust
    assert_equal [ "marie@example.com", "sam@example.com", "ana@example.com" ], options.allowed_emails
  end

  def test_allow_domain_implies_domain_trust
    options = parse "@clawdito", "--project", "A", "--allow-domain", "example.com"

    assert_equal :domain, options.trust
    assert_equal [ "example.com" ], options.allowed_domains
  end

  def test_trust_domain_alone_uses_the_default_domain
    options = parse "@clawdito", "--project", "A", "--trust", "domain"

    assert_equal :domain, options.trust
    assert_empty options.allowed_domains
  end

  def test_allow_project_implies_project_trust
    options = parse "@clawdito", "--project", "A", "--allow-project"

    assert_equal :project, options.trust
  end

  def test_parses_the_assignment_opt_in
    options = parse "@clawdito", "--project", "A", "--allow-project", "--allow-assignments-from-authorized"

    assert options.allow_assignments
  end

  def test_parses_the_chat_poll_interval
    assert_equal 15, parse("@clawdito", "--project", "A").chat_poll
    assert_equal 60, parse("@clawdito", "--project", "A", "--chat-poll", "60").chat_poll
  end

  def test_refuses_a_non_positive_chat_poll_interval
    assert_raises ArgumentError do
      parse "@clawdito", "--project", "A", "--chat-poll", "0"
    end
  end

  def test_refuses_types_that_reduce_to_nothing
    assert_raises ArgumentError do
      parse "@clawdito", "--project", "A", "--types", " , "
    end
  end

  def test_parses_the_boost_poll_interval
    assert_equal 60, parse("@clawdito", "--project", "A").boost_poll
    assert_equal 120, parse("@clawdito", "--project", "A", "--boost-poll", "120").boost_poll
    assert_nil parse("@clawdito", "--project", "A", "--no-boosts").boost_poll
  end

  def test_refuses_a_non_positive_boost_poll_interval
    assert_raises ArgumentError do
      parse "@clawdito", "--project", "A", "--boost-poll", "0"
    end
  end

  def test_refuses_value_flags_that_imply_different_trust_modes
    assert_raises ArgumentError do
      parse "@clawdito", "--project", "A", "--allow", "marie@example.com", "--allow-domain", "example.com"
    end
  end

  def test_refuses_an_explicit_trust_mode_contradicted_by_a_value_flag
    assert_raises ArgumentError do
      parse "@clawdito", "--project", "A", "--trust", "operator", "--allow", "marie@example.com"
    end
  end

  def test_refuses_an_allowlist_with_no_allowed_emails
    assert_raises ArgumentError do
      parse "@clawdito", "--project", "A", "--trust", "allowlist"
    end
  end

  def test_refuses_a_repeated_trust_flag_with_different_modes
    assert_raises ArgumentError do
      parse "@clawdito", "--project", "A", "--trust", "operator", "--trust", "project"
    end
  end

  def test_allows_a_repeated_trust_flag_with_the_same_mode
    options = parse "@clawdito", "--project", "A", "--trust", "project", "--trust", "project"

    assert_equal :project, options.trust
  end

  def test_parses_github_only_without_an_agent
    options = BasecampAgentConnector::Connector.parse_options([ "--repo", "basecamp/bc3" ])

    assert_nil options.agent
    assert_empty options.projects
    assert_equal [ "basecamp/bc3" ], options.repos
  end

  def test_parses_both_transports_together
    options = BasecampAgentConnector::Connector.parse_options(
      [ "@clawdito", "--project", "A", "--repo", "acme/a", "--repo", "acme/b", "--operator", "jorge", "--port", "4567" ])

    assert_equal "clawdito", options.agent
    assert_equal [ "A" ], options.projects
    assert_equal [ "acme/a", "acme/b" ], options.repos
    assert_equal "jorge", options.operator
    assert_equal 4567, options.port
  end

  def test_parses_the_github_operator_login
    assert_nil parse("--repo", "acme/a").gh_operator
    assert_equal "octocat", parse("--repo", "acme/a", "--gh-operator", " octocat ").gh_operator
    assert_equal "octocat", parse("--repo", "acme/a", "--gh-operator", "@octocat").gh_operator
  end

  def test_refuses_an_empty_github_operator_login
    assert_raises ArgumentError do
      parse "--repo", "acme/a", "--gh-operator", " "
    end
    assert_raises ArgumentError do
      parse "--repo", "acme/a", "--gh-operator", "@"
    end
  end

  def test_parses_comma_separated_github_events
    options = BasecampAgentConnector::Connector.parse_options([ "--repo", "acme/a", "--events", "pull_request_review, issue_comment" ])

    assert_equal [ "pull_request_review", "issue_comment" ], options.events
  end

  def test_requires_at_least_one_project_or_repo
    assert_raises ArgumentError do
      BasecampAgentConnector::Connector.parse_options([ "@clawdito" ])
    end
  end

  def test_requires_an_agent_when_watching_projects
    assert_raises ArgumentError do
      BasecampAgentConnector::Connector.parse_options([ "--project", "Queenbee" ])
    end
  end

  class FakeServer
    def start; end
    def stop; end
  end

  def test_start_mounts_only_its_own_bridge_paths_on_the_shared_funnel
    runner = github_runner

    start_connector [ "--repo", "acme/a", "--port", "4567" ], runner

    mounted = runner.commands_matching(/funnel --bg/)
    assert_equal 1, mounted.length
    path = mounted.first[4]
    assert_match %r{\A/gh/[0-9a-f]+\z}, path
    assert_equal [ "tailscale", "funnel", "--bg", "--set-path", path, "http://127.0.0.1:4567#{path}" ], mounted.first
    assert_equal [ [ "tailscale", "funnel", "--set-path", path, "off" ] ], runner.commands_matching(/funnel --set-path/)
    assert_empty runner.commands_matching(/reset/)
  end

  def test_start_trusts_the_login_gh_is_signed_in_as_by_default
    runner = github_runner

    _out, err = start_connector [ "--repo", "acme/a", "--port", "4567" ], runner

    assert_equal 1, runner.commands_matching(/\Agh api user\z/).length
    assert_match(/^Trust: approvals from @octocat only/, err)
  end

  def test_start_trusts_the_given_github_operator_without_asking_gh
    runner = github_runner

    _out, err = start_connector [ "--repo", "acme/a", "--gh-operator", "marie", "--port", "4567" ], runner

    assert_empty runner.commands_matching(/\Agh api user\z/)
    assert_match(/^Trust: approvals from @marie only/, err)
  end

  def test_start_aborts_when_gh_is_signed_out_and_no_github_operator_is_given
    runner = FakeCommandRunner.new
    runner.stub "gh api user", exit_status: 4, stderr: "gh: not logged in"
    connector = BasecampAgentConnector::Connector.new(parse("--repo", "acme/a", "--port", "4567"))
    connector.instance_variable_set(:@command_runner, runner)

    _out, err = capture_io do
      assert_raises(SystemExit) { connector.start }
    end

    assert_match(/Could not resolve the operator's GitHub login: .*not logged in/, err)
    assert_match(/--gh-operator LOGIN/, err)
    assert_empty runner.commands_matching(%r{/hooks})
    assert_empty runner.commands_matching(/\Atailscale/)
  end

  def test_start_skips_the_funnel_entirely_for_a_chat_only_run
    runner = FakeCommandRunner.new
    runner.stub "basecamp me --profile clawdito", stdout: JSON.generate("ok" => true, "data" => { "identity" => { "id" => 1, "email_address" => "clawdito@example.com", "first_name" => "Clawdito" } })
    runner.stub "basecamp me", stdout: JSON.generate("ok" => true, "data" => { "identity" => { "id" => 2, "email_address" => "operator@example.com", "first_name" => "Operator" } })
    runner.stub "people show me", stdout: JSON.generate("ok" => true, "data" => { "id" => 52007412 })
    runner.stub "chat list", stdout: "[]"

    _out, err = start_connector [ "@clawdito", "--project", "123", "--types", "Chat::Line", "--port", "4567" ], runner

    assert_empty runner.commands_matching(/\Atailscale/)
    assert_empty runner.commands_matching(/webhooks/)
    assert_match(/Polling 0 Campfire\(s\)/, err)
  end

  def test_parses_the_duplicate_opt_in
    refute parse("@clawdito", "--project", "A").allow_duplicate
    assert parse("@clawdito", "--project", "A", "--allow-duplicate").allow_duplicate
  end

  # The failure this prevents: two connectors on one agent and project, so
  # Basecamp delivers every event to both and the agent answers twice.
  def test_refuses_to_start_beside_a_live_run_on_the_same_agent_and_project
    with_registry do |registry|
      registry.record(agent: "clawdito", operator: "jorge", projects: [ "Queenbee" ], repos: [], paths: [ "/bc5/live" ], boosts: true)
      connector = connector(registry, "@clawdito", "--project", "Queenbee")

      error = assert_raises SystemExit do
        capture_stderr { connector.send(:reserve_run) }
      end

      refute_equal 0, error.status
    end
  end

  def test_allow_duplicate_starts_anyway
    with_registry do |registry|
      registry.record(agent: "clawdito", operator: "jorge", projects: [ "Queenbee" ], repos: [], paths: [], boosts: true)
      connector = connector(registry, "@clawdito", "--project", "Queenbee", "--allow-duplicate")

      connector.send(:reserve_run)
    end
  end

  def test_a_live_run_on_another_agent_is_not_a_duplicate
    with_registry do |registry|
      registry.record(agent: "chef", operator: "jorge", projects: [ "Queenbee" ], repos: [], paths: [], boosts: true)

      connector(registry, "@clawdito", "--project", "Queenbee").send(:reserve_run)
    end
  end

  # Reserving is what makes the refusal binding: the run is recorded under the
  # same lock that checked for duplicates.
  def test_reserving_records_the_run_before_any_bridge_exists
    with_registry do |registry|
      connector(registry, "@clawdito", "--project", "Queenbee").send(:reserve_run)

      assert_equal [ Process.pid ], registry.live.map(&:pid)
      assert_empty registry.live.first.paths
    end
  end

  # Without a record there is no duplicate detection and no way to attribute
  # the webhooks this run is about to register, so it must not start.
  def test_refuses_to_start_when_the_run_cannot_be_recorded
    registry = BasecampAgentConnector::RunRegistry.new(directory: "/proc/nope/runs")
    connector = BasecampAgentConnector::Connector.new(parse("@clawdito", "--project", "Queenbee"), registry: registry)

    error = assert_raises SystemExit do
      capture_stderr { connector.send(:reserve_run) }
    end

    refute_equal 0, error.status
  end

  # Same agent, no overlap: legal, but the received-boosts feed is per-agent,
  # so both runs would dispatch every boost.
  def test_warns_when_the_same_agent_runs_elsewhere_with_boosts_on
    with_registry do |registry|
      registry.record(agent: "clawdito", operator: "jorge", projects: [ "Queenbee" ], repos: [], paths: [], boosts: true)

      warnings = capture_stderr do
        connector(registry, "@clawdito", "--project", "BC5.1").send(:reserve_run)
      end

      assert_match(/already being watched/, warnings)
      assert_match(/--no-boosts/, warnings)
    end
  end

  # A GitHub-only run has no agent, so another agentless run is not "the same
  # agent" and shares no per-agent feed with it.
  def test_does_not_warn_about_an_unrelated_github_only_run
    with_registry do |registry|
      registry.record(agent: nil, operator: "jorge", projects: [], repos: [ "acme/b" ], paths: [ "/gh/live" ], boosts: false)

      warnings = capture_stderr do
        connector(registry, "--repo", "acme/a").send(:reserve_run)
      end

      assert_empty warnings
    end
  end

  # Nothing polls boosts without a Basecamp bridge, whatever --boost-poll says.
  def test_a_github_only_run_records_no_boost_polling
    with_registry do |registry|
      connector(registry, "--repo", "acme/a").send(:reserve_run)

      refute registry.live.first.boosts
    end
  end

  def test_a_basecamp_run_records_its_boost_polling
    with_registry do |registry|
      connector(registry, "@clawdito", "--project", "Queenbee").send(:reserve_run)

      assert registry.live.first.boosts
    end
  end

  def test_status_names_the_paths_a_live_run_owns
    with_registry do |registry|
      registry.record(agent: "clawdito", operator: "jorge", projects: [ "Queenbee" ], repos: [ "basecamp/bc3" ],
        paths: [ "/bc5/abc", "/gh/def" ], boosts: false)

      output = capture_stdout { BasecampAgentConnector::Connector.print_status(registry: registry) }

      assert_match(/1 connector\(s\) running/, output)
      assert_match(%r{/bc5/abc, /gh/def}, output)
      assert_match(/belongs to a LIVE run/, output)
    end
  end

  # A dead run's entry is the only record of the paths it owned, and the next
  # startup is what sweeps them. Status must leave it alone.
  def test_status_leaves_a_dead_run_for_the_next_startup_to_sweep
    with_registry do |registry, directory|
      File.write File.join(directory, "4194303.json"), JSON.generate(
        pid: 4_194_303, started_at: "2026-09-01T00:00:00Z", agent: "clawdito", operator: "jorge",
        projects: [ "Queenbee" ], repos: [], paths: [ "/bc5/orphan" ], boosts: true)

      capture_stdout { BasecampAgentConnector::Connector.print_status(registry: registry, command_runner: no_processes) }

      assert_equal [ "/bc5/orphan" ], registry.prune.flat_map(&:paths)
    end
  end

  def test_status_with_nothing_running
    with_registry do |registry|
      output = capture_stdout { BasecampAgentConnector::Connector.print_status(registry: registry, command_runner: no_processes) }

      assert_match(/No connector recorded as running/, output)
    end
  end

  # The transition case, and the one that caused the damage: a connector from
  # an older build records nothing, so silence here would read as "nothing
  # running" while its webhooks sit unattributable in Basecamp.
  def test_status_calls_out_a_running_connector_the_registry_does_not_know
    with_registry do |registry|
      output = capture_stdout do
        BasecampAgentConnector::Connector.print_status(registry: registry, command_runner: processes(4_194_302))
      end

      assert_match(/NOT recorded: 4194302/, output)
      assert_match(/cannot be attributed/, output)
    end
  end

  def test_status_does_not_report_a_recorded_run_as_unrecorded
    with_registry do |registry|
      registry.record(agent: "clawdito", operator: "jorge", projects: [ "Queenbee" ], repos: [], paths: [], boosts: true)

      output = capture_stdout do
        BasecampAgentConnector::Connector.print_status(registry: registry, command_runner: processes(Process.pid))
      end

      refute_match(/NOT recorded/, output)
    end
  end

  private
    def with_registry
      Dir.mktmpdir do |directory|
        yield BasecampAgentConnector::RunRegistry.new(directory: directory), directory
      end
    end

    def connector(registry, *arguments)
      BasecampAgentConnector::Connector.new(parse(*arguments), registry: registry)
    end

    def no_processes
      processes
    end

    # A pid with no /proc entry: `watching_process?` errs toward reporting it,
    # which is the behavior under test.
    def processes(*pids)
      runner = FakeCommandRunner.new
      runner.stub "pgrep", stdout: pids.join("\n")
      runner
    end

    def capture_stderr
      original, $stderr = $stderr, StringIO.new
      yield
      $stderr.string
    ensure
      $stderr = original
    end

    def capture_stdout
      original, $stdout = $stdout, StringIO.new
      yield
      $stdout.string
    ensure
      $stdout = original
    end
    def parse(*argv)
      BasecampAgentConnector::Connector.parse_options(argv)
    end

    # Everything a `--repo` run shells out for, with `gh` signed in as octocat.
    def github_runner
      runner = FakeCommandRunner.new
      runner.stub "tailscale funnel", exit_status: 0
      runner.stub "tailscale status --json", stdout: JSON.generate("Self" => { "DNSName" => "desktop.example.ts.net." })
      runner.stub "/hooks", stdout: '{"id":888}'
      runner.stub "-X DELETE", exit_status: 0
      runner.stub "gh api user", stdout: JSON.generate("login" => "octocat")
      runner
    end

    def start_connector(argv, runner)
      connector = BasecampAgentConnector::Connector.new(BasecampAgentConnector::Connector.parse_options(argv))
      connector.instance_variable_set(:@command_runner, runner)

      BasecampAgentConnector::Server.stub(:new, FakeServer.new) { capture_io { connector.start } }
    end
end
