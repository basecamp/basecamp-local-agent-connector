require "json"

class BasecampAgentConnector::Basecamp::Client
  class Error < StandardError; end

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

  def show(url_or_id)
    json "show", url_or_id
  end

  def chats(project:)
    Array json("chat", "list", "--project", project.to_s)
  end

  def chat_lines(project:, chat:, limit:)
    Array json("chat", "messages", "--project", project.to_s, "--room", chat.to_s, "--limit", limit.to_s)
  end

  def chat_line(url_or_id)
    json "chat", "line", url_or_id
  end

  def subscription(url_or_id)
    json "subscriptions", "show", url_or_id
  end

  # The boosts the profile's user has received (bc3's `/my/boosts.json` — the
  # report behind the "You've got Boosts!" notification), newest first. The CLI
  # has no dedicated command for the received-boosts feed, so go through its
  # raw API passthrough.
  def received_boosts(profile:)
    Array json("api", "get", "/my/boosts.json", *profile_flag(profile))
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
    rescue JSON::ParserError => error
      # A truncated or garbled success is a failed command, not a crash:
      # every caller already rescues Error, so it stays on the same path.
      raise Error, "`basecamp #{arguments.join(' ')}` returned malformed JSON: #{error.message}"
    end

    # `-j` wraps every result in an envelope — {"ok": ..., "data": ...,
    # "summary": ...} — and an empty result may omit "data" entirely:
    # `chat messages` on a room with no lines returns just
    # {"ok": true, "summary": "0 messages"} (verified against production).
    # So the envelope is recognized by its "ok" marker, not by "data" —
    # keying on "data" hands the bare envelope back for an empty room, and
    # Array() on that hash downstream explodes it into ["ok", true]-style
    # pairs whose ["id"] lookups raise TypeError.
    def unwrap(parsed)
      if parsed.is_a?(Hash) && parsed.key?("ok")
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
