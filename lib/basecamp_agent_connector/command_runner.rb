require "open3"

class BasecampAgentConnector::CommandRunner
  Result = Data.define(:stdout, :stderr, :exit_status) do
    def success?
      exit_status.zero?
    end
  end

  # `env` is added to the environment the command runs in.
  def run(*command, env: {})
    stdout, stderr, status = Open3.capture3(env, *command)
    Result.new(stdout: stdout, stderr: stderr, exit_status: status.exitstatus)
  end
end
