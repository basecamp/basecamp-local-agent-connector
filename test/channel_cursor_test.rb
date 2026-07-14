require "test_helper"
require "tmpdir"

class ChannelCursorTest < Minitest::Test
  def test_starts_at_zero_when_no_file_exists
    Dir.mktmpdir do |dir|
      cursor = BasecampAgentConnector::Channel::Cursor.new(agent: "clawdito", operator: "jorge", dir: dir)
      assert_equal 0, cursor.position
    end
  end

  def test_advances_and_persists_across_instances
    Dir.mktmpdir do |dir|
      BasecampAgentConnector::Channel::Cursor.new(agent: "clawdito", operator: "jorge", dir: dir).advance(42)

      reopened = BasecampAgentConnector::Channel::Cursor.new(agent: "clawdito", operator: "jorge", dir: dir)
      assert_equal 42, reopened.position
    end
  end

  def test_partitions_by_agent_and_operator
    Dir.mktmpdir do |dir|
      BasecampAgentConnector::Channel::Cursor.new(agent: "clawdito", operator: "jorge", dir: dir).advance(10)
      other = BasecampAgentConnector::Channel::Cursor.new(agent: "clawdito", operator: "kasper", dir: dir)

      assert_equal 0, other.position
    end
  end
end
