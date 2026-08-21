require "open3"

class BasecampAgentConnector::CommandRunner
  Result = Data.define(:stdout, :stderr, :exit_status) do
    # A command killed by a signal reports no exit status at all, which happens
    # routinely on shutdown: the interrupt that stops the process reaches the
    # `basecamp` call it was waiting on too. Comparing rather than asking that nil
    # whether it is zero keeps teardown from raising over an unfinished read.
    def success?
      exit_status == 0
    end
  end

  def run(*command)
    stdout, stderr, status = Open3.capture3(*command)
    Result.new(stdout: stdout, stderr: stderr, exit_status: status.exitstatus)
  end
end
