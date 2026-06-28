require "test_helper"

class ProjectsTest < Minitest::Test
  def test_returns_explicit_projects_without_calling_basecamp
    runner = FakeCommandRunner.new

    watched = BasecampAgentConnector::Projects.new(basecamp_cli: build_cli(runner)).watched(explicit: [ "A", "B" ])

    assert_equal [ "A", "B" ], watched
    assert_empty runner.commands
  end

  def test_enumerates_all_accessible_projects_when_none_given
    runner = FakeCommandRunner.new
    runner.stub "basecamp projects", stdout: envelope([ { "id" => 1 }, { "id" => 2 } ])

    watched = BasecampAgentConnector::Projects.new(basecamp_cli: build_cli(runner)).watched(explicit: [])

    assert_equal [ 1, 2 ], watched
  end
end
