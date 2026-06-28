require "json"

class BasecampAgentConnector::BasecampCLI
  class Error < StandardError; end

  def initialize(command_runner: BasecampAgentConnector::CommandRunner.new, executable: "basecamp")
    @command_runner = command_runner
    @executable = executable
  end

  def me
    json "me"
  end

  def refresh_auth
    run("auth", "refresh").success?
  end

  def show(url_or_id)
    json "show", url_or_id
  end

  def create_webhook(url:, project:, types:)
    json "webhooks", "create", url, "--project", project.to_s, "--types", types
  end

  def delete_webhook(id:, project:)
    run("webhooks", "delete", id.to_s, "--project", project.to_s).success?
  end

  private
    def json(*arguments)
      result = run(*arguments, "-j")

      unless result.success?
        detail = result.stderr.strip
        detail = result.stdout.strip if detail.empty?
        raise Error, "`basecamp #{arguments.join(' ')}` failed: #{detail}"
      end

      unwrap JSON.parse(result.stdout)
    end

    def unwrap(parsed)
      if parsed.is_a?(Hash) && parsed.key?("data")
        parsed["data"]
      else
        parsed
      end
    end

    def run(*arguments)
      @command_runner.run(@executable, *arguments)
    end
end
