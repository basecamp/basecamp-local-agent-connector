require "test_helper"

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
  end

  def test_refuses_an_empty_github_operator_login
    assert_raises ArgumentError do
      parse "--repo", "acme/a", "--gh-operator", " "
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

  private
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
