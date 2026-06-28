require "test_helper"

class CLITest < Minitest::Test
  def test_parses_trigger_and_project_with_defaults
    options = BasecampAgentConnector::CLI.parse_options([ "@agent", "--project", "Queenbee" ])

    assert_equal "@agent", options.trigger
    assert_equal [ "Queenbee" ], options.projects
    assert_equal "Comment,Message,Kanban::Card", options.types
    assert_nil options.port
  end

  def test_parses_repeatable_projects_and_flags
    options = BasecampAgentConnector::CLI.parse_options([ "@agent", "--project", "A", "--project", "B", "--types", "Comment", "--port", "4567" ])

    assert_equal [ "A", "B" ], options.projects
    assert_equal "Comment", options.types
    assert_equal 4567, options.port
  end

  def test_requires_a_trigger
    assert_raises ArgumentError do
      BasecampAgentConnector::CLI.parse_options([ "--project", "Queenbee" ])
    end
  end

  def test_requires_a_project
    assert_raises ArgumentError do
      BasecampAgentConnector::CLI.parse_options([ "@agent" ])
    end
  end
end
