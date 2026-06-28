require "open3"

class BasecampAgentConnector::CommandRunner
  Result = Data.define(:stdout, :stderr, :exit_status) do
    def success?
      exit_status.zero?
    end
  end

  def run(*command)
    stdout, stderr, status = Open3.capture3(*command)
    Result.new(stdout: stdout, stderr: stderr, exit_status: status.exitstatus)
  end
end
