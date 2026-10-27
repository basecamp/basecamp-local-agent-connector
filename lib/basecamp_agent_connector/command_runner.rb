require "open3"

class BasecampAgentConnector::CommandRunner
  Result = Data.define(:stdout, :stderr, :exit_status) do
    def success?
      exit_status.zero?
    end
  end

  # `chdir` runs the command in another directory without touching this
  # process's own: a dispatched session starts in the repo its task belongs to,
  # and the connector goes on serving webhooks from wherever it was launched.
  def run(*command, chdir: nil)
    stdout, stderr, status = Open3.capture3(*command, **(chdir.nil? ? {} : { chdir: chdir }))
    Result.new(stdout: stdout, stderr: stderr, exit_status: status.exitstatus)
  end
end
