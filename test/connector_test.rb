require "test_helper"

class ConnectorTest < Minitest::Test
  def test_parses_basecamp_with_a_connection_token_and_host
    options = BasecampAgentConnector::Connector.parse_options(
      [ "@Clawdito", "--connection-token", "tok-123", "--host", "https://3.basecamp.com/1234567" ])

    assert_equal "clawdito", options.agent
    assert_equal "tok-123", options.connection_token
    assert_equal "https://3.basecamp.com/1234567", options.host
    assert options.watch_basecamp?
    refute options.watch_github?
  end

  def test_parses_github_only_without_an_agent
    options = BasecampAgentConnector::Connector.parse_options([ "--repo", "basecamp/bc3" ])

    assert_nil options.agent
    assert_equal [ "basecamp/bc3" ], options.repos
    assert options.watch_github?
    refute options.watch_basecamp?
  end

  def test_parses_both_transports_together
    options = BasecampAgentConnector::Connector.parse_options(
      [ "@clawdito", "--connection-token", "tok", "--host", "https://example.com/1", "--repo", "acme/a", "--port", "4567" ])

    assert options.watch_basecamp?
    assert options.watch_github?
    assert_equal 4567, options.port
  end

  def test_parses_comma_separated_github_events
    options = BasecampAgentConnector::Connector.parse_options([ "--repo", "acme/a", "--events", "pull_request_review, issue_comment" ])

    assert_equal [ "pull_request_review", "issue_comment" ], options.events
  end

  def test_requires_something_to_watch
    assert_raises ArgumentError do
      BasecampAgentConnector::Connector.parse_options([])
    end
  end

  def test_basecamp_requires_a_connection_token
    assert_raises ArgumentError do
      BasecampAgentConnector::Connector.parse_options([ "@clawdito" ])
    end
  end

  def test_basecamp_requires_a_host
    assert_raises ArgumentError do
      BasecampAgentConnector::Connector.parse_options([ "@clawdito", "--connection-token", "tok" ])
    end
  end
end
