require "json"

class BasecampAgentConnector::Basecamp::Client
  class Error < StandardError; end

  # Only the keychain contention below is retried. Every other failure -- a 404,
  # a bad argument, a real logout -- is returned on the first attempt, because
  # retrying it just spends the interval saying the same thing.
  CREDENTIAL_LOCK = /credentials not found|not authenticated for profile/i

  RETRY_DELAYS = [ 0.15, 0.4, 1.0 ].freeze

  def initialize(command_runner: BasecampAgentConnector::CommandRunner.new, executable: "basecamp")
    @command_runner = command_runner
    @executable = executable
  end

  def me(profile: nil)
    json "me", *profile_flag(profile)
  end

  def person(profile: nil)
    json "people", "show", "me", *profile_flag(profile)
  end

  def refresh_auth(profile: nil)
    run("auth", "refresh", *profile_flag(profile)).success?
  end

  def show(url_or_id, profile: nil)
    json "show", url_or_id, *profile_flag(profile)
  end

  def project(id_or_name, profile: nil)
    json "projects", "show", id_or_name.to_s, *profile_flag(profile)
  end

  def notifications(profile: nil)
    json "notifications", "list", *profile_flag(profile)
  end

  def cards_in_column(project:, column:, profile: nil)
    json "cards", "list", "--project", project.to_s, "--column", column.to_s, *profile_flag(profile)
  end

  # Account-wide, and the only listing that reports assignment at all: a
  # project-scoped card listing omits `assignees` entirely, so detecting an
  # assignment from one would cost a fetch per card on the board.
  def cards_assigned_to(assignee, profile: nil)
    json "cards", "list", "--all-projects", "--assignee", assignee.to_s, *profile_flag(profile)
  end

  def events(id_or_url, profile: nil)
    json "events", id_or_url.to_s, *profile_flag(profile)
  end

  def create_webhook(url:, project:, types:)
    json "webhooks", "create", url, "--project", project.to_s, "--types", types
  end

  def delete_webhook(id:, project:)
    run("webhooks", "delete", id.to_s, "--project", project.to_s).success?
  end

  private
    def json(*arguments)
      result = attempt(*arguments)

      unless result.success?
        detail = detail_of(result)
        raise Error, "`basecamp #{arguments.join(' ')}` failed: #{detail}"
      end

      unwrap JSON.parse(result.stdout)
    end

    # The CLI keeps credentials in the keychain and reads them under a global
    # mutual exclusion: measured 2026-08-21 at concurrency 1, 2, 3, 4 and 8,
    # exactly ONE simultaneous call comes back authenticated and every other one
    # reports the profile logged out, whatever profiles they name. A serial read
    # always succeeds, so the loser of a race is not out of credentials -- it was
    # standing in the wrong place. Retry it, spaced so the retries do not collide
    # with each other the way the originals did.
    def attempt(*arguments)
      RETRY_DELAYS.each do |delay|
        result = run(*arguments, "-j")
        return result if result.success? || !locked_out?(result)

        sleep delay
      end

      run(*arguments, "-j")
    end

    def locked_out?(result)
      CREDENTIAL_LOCK.match? detail_of(result)
    end

    def detail_of(result)
      detail = result.stderr.strip
      detail.empty? ? result.stdout.strip : detail
    end

    def unwrap(parsed)
      if parsed.is_a?(Hash) && parsed.key?("data")
        parsed["data"]
      else
        parsed
      end
    end

    def profile_flag(profile)
      profile ? [ "--profile", profile ] : []
    end

    def run(*arguments)
      @command_runner.run(@executable, *arguments)
    end
end
