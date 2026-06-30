require "test_helper"

class ReviewCLITest < Minitest::Test
  def test_parses_repos_with_defaults
    options = BasecampAgentConnector::ReviewCLI.parse_options([ "basecamp/bc3" ])

    assert_equal [ "basecamp/bc3" ], options.repos
    assert_equal "pull_request_review", options.events
    assert_nil options.port
  end

  def test_parses_multiple_repos_and_flags
    options = BasecampAgentConnector::ReviewCLI.parse_options([ "acme/a", "acme/b", "--events", "pull_request_review,issue_comment", "--port", "4567" ])

    assert_equal [ "acme/a", "acme/b" ], options.repos
    assert_equal "pull_request_review,issue_comment", options.events
    assert_equal 4567, options.port
  end

  def test_requires_a_repo
    assert_raises ArgumentError do
      BasecampAgentConnector::ReviewCLI.parse_options([ "--port", "4567" ])
    end
  end
end
