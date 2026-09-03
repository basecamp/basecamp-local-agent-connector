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

  def test_parses_the_webhook_check_interval
    assert_equal 300, parse("@clawdito", "--project", "A").webhook_check
    assert_equal 60, parse("@clawdito", "--project", "A", "--webhook-check", "60").webhook_check
  end

  def test_refuses_a_non_positive_webhook_check_interval
    assert_raises ArgumentError do
      parse "@clawdito", "--project", "A", "--webhook-check", "0"
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

  # The failure this prevents: `BASECAMP_PROFILE` pinned to the agent's profile
  # and no --operator, so the unflagged `basecamp me` answers as the agent and
  # the connector runs with nobody able to trigger it.
  def test_start_refuses_an_operator_who_is_the_agent
    runner = FakeCommandRunner.new
    runner.stub "basecamp me", stdout: JSON.generate("ok" => true, "data" => { "identity" => { "id" => 1, "email_address" => "clawdito@example.com", "first_name" => "Clawdito" } })
    runner.stub "people show me", stdout: JSON.generate("ok" => true, "data" => { "id" => 52007412 })

    _out, err = with_env("BASECAMP_PROFILE" => "clawdito") do
      start_connector [ "@clawdito", "--project", "123", "--types", "Chat::Line", "--port", "4567" ], runner, expect_exit: true
    end

    assert_match(/same Basecamp user \(clawdito@example.com\)/, err)
    assert_match(/BASECAMP_PROFILE=clawdito is set and --operator is not/, err)
    assert_empty runner.commands_matching(/chat list/)
  end

  # No email on either side: the match is on the identity id, and the id is
  # what the message can name.
  def test_start_refuses_an_operator_who_is_the_agent_without_blaming_the_environment
    runner = FakeCommandRunner.new
    runner.stub "basecamp me", stdout: JSON.generate("ok" => true, "data" => { "identity" => { "id" => 28142355 } })
    runner.stub "people show me", stdout: JSON.generate("ok" => true, "data" => { "id" => 52007412 })

    _out, err = with_env("BASECAMP_PROFILE" => nil) do
      start_connector [ "@clawdito", "--project", "123", "--types", "Chat::Line", "--operator", "clawdito" ], runner, expect_exit: true
    end

    assert_match(/operator \(profile clawdito\) are the same Basecamp user \(28142355\)/, err)
    assert_match(/distinct bot user/, err)
    refute_match(/BASECAMP_PROFILE/, err)
  end

  # A run killed without teardown leaves its file as the only record of the
  # paths it owned; a start that is refused must not be the one to consume it.
  def test_a_refused_start_leaves_dead_run_records_for_the_next_one_to_sweep
    with_registry do |registry, directory|
      orphan = File.join(directory, "4194303.json")
      File.write orphan, JSON.generate(pid: 4_194_303, started_at: "2026-09-01T00:00:00Z", agent: "clawdito", operator: "jorge",
        projects: [ "123" ], repos: [], paths: [ "/bc5/orphan" ], boosts: true)
      runner = FakeCommandRunner.new
      runner.stub "basecamp me", stdout: JSON.generate("ok" => true, "data" => { "identity" => { "id" => 1, "email_address" => "clawdito@example.com" } })
      runner.stub "people show me", stdout: JSON.generate("ok" => true, "data" => { "id" => 52007412 })

      with_env("BASECAMP_PROFILE" => nil) do
        start_connector [ "@clawdito", "--project", "123", "--types", "Chat::Line", "--operator", "clawdito" ], runner, registry: registry, expect_exit: true
      end

      assert_path_exists orphan
    end
  end

  def test_start_makes_every_operator_side_call_under_the_operator_profile
    runner = FakeCommandRunner.new
    runner.stub "basecamp me --profile clawdito", stdout: JSON.generate("ok" => true, "data" => { "identity" => { "id" => 1, "email_address" => "clawdito@example.com", "first_name" => "Clawdito" } })
    runner.stub "basecamp me", stdout: JSON.generate("ok" => true, "data" => { "identity" => { "id" => 2, "email_address" => "jorge@example.com", "first_name" => "Jorge" } })
    runner.stub "people show me", stdout: JSON.generate("ok" => true, "data" => { "id" => 52007412 })
    runner.stub "chat list", stdout: "[]"

    start_connector [ "@clawdito", "--project", "123", "--types", "Chat::Line", "--operator", "jorge", "--port", "4567" ], runner

    assert_equal 1, runner.commands_matching(/\Abasecamp me --profile jorge -j\z/).length
    assert_equal 1, runner.commands_matching(/chat list/).length
    assert_match(/--profile jorge/, runner.commands_matching(/chat list/).first.join(" "))
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
        capture_stderr { connector.send(:refuse_duplicate_run) }
      end

      refute_equal 0, error.status
    end
  end

  def test_allow_duplicate_starts_anyway
    with_registry do |registry|
      registry.record(agent: "clawdito", operator: "jorge", projects: [ "Queenbee" ], repos: [], paths: [], boosts: true)
      connector = connector(registry, "@clawdito", "--project", "Queenbee", "--allow-duplicate")

      connector.send(:refuse_duplicate_run)
    end
  end

  def test_a_live_run_on_another_agent_is_not_a_duplicate
    with_registry do |registry|
      registry.record(agent: "chef", operator: "jorge", projects: [ "Queenbee" ], repos: [], paths: [], boosts: true)

      connector(registry, "@clawdito", "--project", "Queenbee").send(:refuse_duplicate_run)
    end
  end

  # Same agent, no overlap: legal, but the received-boosts feed is per-agent,
  # so both runs would dispatch every boost.
  def test_warns_when_the_same_agent_runs_elsewhere_with_boosts_on
    with_registry do |registry|
      registry.record(agent: "clawdito", operator: "jorge", projects: [ "Queenbee" ], repos: [], paths: [], boosts: true)

      warnings = capture_stderr do
        connector(registry, "@clawdito", "--project", "BC5.1").send(:warn_of_same_agent_elsewhere)
      end

      assert_match(/already being watched/, warnings)
      assert_match(/--no-boosts/, warnings)
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

  # Claude Code launches a connector as `bash -c '… bin/connect @agent …'` and
  # that shell stays alive as the parent, so `pgrep -f` hands back two pids per
  # connector; only the ruby process is one.
  def test_status_does_not_count_the_shell_that_launched_a_connector
    with_registry do |registry|
      runner = processes(
        4_194_301 => "/opt/homebrew/bin/bash -c source snapshot.sh && eval 'cd connector && bin/connect @clawdito --project \"App Security\"'",
        4_194_302 => "ruby bin/connect @clawdito --project App Security")

      output = without_procfs { capture_stdout { BasecampAgentConnector::Connector.print_status(registry: registry, command_runner: runner) } }

      assert_match(/NOT recorded: 4194302\./, output)
    end
  end

  def test_status_does_not_count_another_status_run
    with_registry do |registry|
      runner = processes(4_194_302 => "ruby bin/connect --status")

      output = without_procfs { capture_stdout { BasecampAgentConnector::Connector.print_status(registry: registry, command_runner: runner) } }

      refute_match(/NOT recorded/, output)
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
        yield BasecampAgentConnector::RunRegistry.new(directory: directory, logger: StringIO.new), directory
      end
    end

    def connector(registry, *arguments)
      BasecampAgentConnector::Connector.new(parse(*arguments), registry: registry)
    end

    def no_processes
      processes
    end

    # Pids beyond any kernel's range, so /proc never has them: on Linux
    # `watching_process?` errs toward reporting each one, which is the behavior
    # under test; elsewhere it asks `ps`, whose answer is stubbed per pid — a
    # connector's command line unless the caller gives one.
    def processes(*pids)
      commands = pids.flat_map { |pid| pid.is_a?(Hash) ? pid.to_a : [ [ pid, "ruby bin/connect @clawdito --project A" ] ] }
      runner = FakeCommandRunner.new
      runner.stub "pgrep", stdout: commands.map(&:first).join("\n")
      commands.each { |pid, command| runner.stub "ps -o command= -p #{pid}", stdout: "#{command}\n" }
      runner
    end

    # The `ps` path, whichever platform the tests run on.
    def without_procfs(&block)
      BasecampAgentConnector::RunRegistry.stub(:procfs?, false, &block)
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

    def start_connector(argv, runner, registry: BasecampAgentConnector::RunRegistry.new, expect_exit: false)
      connector = BasecampAgentConnector::Connector.new(BasecampAgentConnector::Connector.parse_options(argv), registry: registry)
      connector.instance_variable_set(:@command_runner, runner)

      BasecampAgentConnector::Server.stub(:new, FakeServer.new) do
        capture_io do
          if expect_exit
            refute_equal 0, assert_raises(SystemExit) { connector.start }.status
          else
            connector.start
          end
        end
      end
    end

    def with_env(variables)
      saved = variables.to_h { |name, _value| [ name, ENV[name] ] }
      variables.each { |name, value| ENV[name] = value }
      yield
    ensure
      saved.each { |name, value| ENV[name] = value }
    end
end
