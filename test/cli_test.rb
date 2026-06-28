require "test_helper"

class CLITest < Minitest::Test
  def test_parses_trigger_and_applies_defaults
    options = BasecampAgentConnector::CLI.parse_options([ "@agent" ])

    assert_equal "@agent", options.trigger
    assert_empty options.projects
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
      BasecampAgentConnector::CLI.parse_options([])
    end
  end
end
