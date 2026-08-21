require "test_helper"

class CommandRunnerTest < Minitest::Test
  def test_a_zero_exit_status_succeeded
    assert result(exit_status: 0).success?
  end

  def test_a_non_zero_exit_status_did_not
    refute result(exit_status: 1).success?
  end

  # A command killed by a signal reports no exit status, which is what every
  # in-flight read looks like when the process is interrupted. Asking that nil
  # whether it is zero used to raise and take the round down with it.
  def test_a_command_killed_by_a_signal_did_not_succeed
    refute result(exit_status: nil).success?
  end

  private
    def result(exit_status:)
      BasecampAgentConnector::CommandRunner::Result.new(stdout: "", stderr: "", exit_status: exit_status)
    end
end
