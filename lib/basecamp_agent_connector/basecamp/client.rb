require "json"

class BasecampAgentConnector::Basecamp::Client
  class Error < StandardError
    # A resource that is permanently absent -- deleted, or never there at all --
    # told apart from every other failure by the code the CLI prints in its JSON
    # envelope. Deliberately narrow, and matched on the message because nothing
    # else survives the raise: every other failure might answer differently a
    # minute from now, and only this one is safe to stop asking about.
    GONE = /"code":\s*"not_found"/

    def gone?
      GONE.match?(message)
    end
  end

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
    listing json("cards", "list", "--project", project.to_s, "--column", column.to_s, *profile_flag(profile))
  end

  # Account-wide, and the only listing that reports assignment at all: a
  # project-scoped card listing omits `assignees` entirely, so detecting an
  # assignment from one would cost a fetch per card on the board.
  def cards_assigned_to(assignee, profile: nil)
    listing json("cards", "list", "--all-projects", "--assignee", assignee.to_s, *profile_flag(profile))
  end

  def events(id_or_url, profile: nil)
    listing json("events", id_or_url.to_s, *profile_flag(profile))
  end

  # The raw API passthrough, and the only way to read a ping.
  #
  # `show` cannot fetch one: handed a line's own API URL it rewrites the path to
  # `recordings/<id>.json` and gets a 404, because a chat line only resolves under
  # its transcript. `api get` passes the path through untouched, and takes either a
  # path or a full URL.
  def get(url_or_path, profile: nil)
    json "api", "get", url_or_path.to_s, *profile_flag(profile)
  end

  def get_listing(url_or_path, profile: nil)
    listing get(url_or_path, profile: profile)
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

    # An empty listing comes back as {"ok": true, "summary": "0 cards"} with NO
    # "data" key, so unwrap hands the envelope itself to a caller expecting rows.
    # `flat_map` does not splay a Hash, so it arrived downstream as one phantom
    # record with a nil id: card_payload built a payload around it, emit dropped
    # it for having no recording id, and remember wrote a blank key that the
    # blank-key guard discarded. Harmless, and harmless only because two guards
    # added for other reasons both happened to catch it.
    def listing(parsed)
      parsed.is_a?(Array) ? parsed : []
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
