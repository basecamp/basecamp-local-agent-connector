require "test_helper"

class ConnectorTest < Minitest::Test
  def test_parses_basecamp_only_with_defaults
    options = BasecampAgentConnector::Connector.parse_options([ "@Clawdito", "--project", "Queenbee" ])

    assert_equal "clawdito", options.agent
    assert_equal [ "Queenbee" ], options.projects
    assert_empty options.repos
    assert_equal "Comment,Message,Kanban::Card,Kanban::Step,Todo", options.types
    assert_equal [ "pull_request_review" ], options.events
    assert_nil options.port
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
end
