require "test_helper"

class CLITest < Minitest::Test
  def test_parses_agent_and_project_with_defaults
    options = BasecampAgentConnector::CLI.parse_options([ "@Clawdito", "--project", "Queenbee" ])

    assert_equal "clawdito", options.agent
    assert_nil options.operator
    assert_equal [ "Queenbee" ], options.projects
    assert_equal "Comment,Message,Kanban::Card", options.types
    assert_nil options.port
  end

  def test_normalizes_agent_strips_at_and_downcases
    assert_equal "clawdito", BasecampAgentConnector::CLI.parse_options([ "@Clawdito", "--project", "X" ]).agent
    assert_equal "clawdito", BasecampAgentConnector::CLI.parse_options([ "clawdito", "--project", "X" ]).agent
  end

  def test_parses_operator_and_other_flags
    options = BasecampAgentConnector::CLI.parse_options([ "@clawdito", "--project", "A", "--operator", "jorge", "--types", "Comment", "--port", "4567" ])

    assert_equal "jorge", options.operator
    assert_equal [ "A" ], options.projects
    assert_equal "Comment", options.types
    assert_equal 4567, options.port
  end

  def test_requires_an_agent
    assert_raises ArgumentError do
      BasecampAgentConnector::CLI.parse_options([ "--project", "Queenbee" ])
    end
  end

  def test_requires_a_project
    assert_raises ArgumentError do
      BasecampAgentConnector::CLI.parse_options([ "@clawdito" ])
    end
  end
end
