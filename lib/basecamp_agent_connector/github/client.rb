require "json"

class BasecampAgentConnector::GitHub::Client
  class Error < StandardError; end

  def initialize(command_runner: BasecampAgentConnector::CommandRunner.new, executable: "gh")
    @command_runner = command_runner
    @executable = executable
  end

  def create_webhook(repo:, url:, secret:, events:)
    arguments = [
      "api", "repos/#{repo}/hooks", "-X", "POST",
      "-f", "name=web",
      "-F", "active=true",
      "-f", "config[url]=#{url}",
      "-f", "config[content_type]=json",
      "-f", "config[secret]=#{secret}"
    ]
    events.each { |event| arguments.push("-f", "events[]=#{event}") }

    json(*arguments)
  end

  def delete_webhook(repo:, id:)
    run("api", "-X", "DELETE", "repos/#{repo}/hooks/#{id}").success?
  end

  # Every hook on the repo, whoever owns it — read so a startup sweep can
  # recognize the ones a dead run of ours left behind.
  def webhooks(repo:)
    Array json("api", "repos/#{repo}/hooks")
  end

  # The login `gh` is authenticated as.
  def authenticated_login
    json("api", "user").fetch("login")
  end

  def review(repo:, pull_number:, id:)
    json "api", "repos/#{repo}/pulls/#{pull_number}/reviews/#{id}"
  end

  def review_comments(repo:, pull_number:, id:)
    json "api", "repos/#{repo}/pulls/#{pull_number}/reviews/#{id}/comments"
  end

  private
    def json(*arguments)
      result = run(*arguments)

      unless result.success?
        detail = result.stderr.strip
        detail = result.stdout.strip if detail.empty?
        raise Error, "`gh #{arguments.join(' ')}` failed: #{detail}"
      end

      JSON.parse(result.stdout)
    end

    def run(*arguments)
      @command_runner.run(@executable, *arguments)
    end
end
