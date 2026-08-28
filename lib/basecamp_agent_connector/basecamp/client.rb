require "json"

class BasecampAgentConnector::Basecamp::Client
  # Basecamp answered, and the answer was no: not found, forbidden, invalid.
  # Asking again cannot change it.
  class Error < StandardError; end

  # The CLI never got an answer out of Basecamp — on any of ATTEMPTS tries.
  # Asking again later may well succeed, so a caller that can defer (a webhook
  # redelivery, the next poll) should, rather than read this as a verdict.
  class TransientError < Error; end

  # The CLI probes the OS keyring on every invocation by writing and deleting
  # one shared item (service "credstore.probe.basecamp"). Concurrent
  # invocations — this connector's pollers plus the agents it dispatches —
  # race on that item; a loser's probe fails, the CLI silently falls back to a
  # stale credentials file, and the command fails with auth_required or a
  # token-refresh api_error although nothing is wrong with the credentials
  # (19/20 parallel probes lost in a 20-way run; 20/20 serial ones passed).
  # The race clears as soon as the neighbours finish, so a failed invocation
  # is tried again after a short, growing pause: ~2s of waiting per command,
  # plus the calls themselves. A verification that runs two commands (a
  # comment on a subscribed recording: `show`, then `subscriptions show`)
  # can still overrun the 10s Basecamp allows a webhook delivery, which the
  # bridge tolerates (see Bridge#handler).
  ATTEMPTS = 3
  RETRY_DELAYS = [ 0.5, 1.5 ] # seconds before the second and third attempt

  # Error-envelope codes that describe the CLI's plight, not Basecamp's
  # answer. `api_error` is ambiguous: Basecamp's own 4xx verdicts arrive as
  # one, but so do three failures to get an answer at all — a token refresh
  # that lost the keyring race ("token refresh failed: …"), bc3 answering 5xx
  # ("Server error (500)" surfaces at once; "Gateway error (502|503|504)" and
  # the generic "API error: 5xx …" are retried inside the SDK for ~3s first
  # and then surface as "request failed after 3 attempts: …", a prefix the
  # SDK puts only on retryable failures), and the CLI's own circuit breaker
  # refusing to ask ("Service temporarily unavailable": file-backed across
  # processes, open for 30s after five consecutive network/5xx failures).
  # The envelope drops the SDK's Retryable flag, so these fixed messages are
  # all there is to key on until the CLI emits that flag — the intended end
  # state, after which this pattern goes.
  TRANSIENT_CODES = %w[auth_required network rate_limit]
  TRANSIENT_API_ERROR = /token refresh|request failed after \d+ attempts?|server error \(500\)|gateway error \(50\d\)|\bAPI error: 5\d\d\b|service temporarily unavailable/i

  def initialize(command_runner: BasecampAgentConnector::CommandRunner.new, executable: "basecamp",
    wait: ->(seconds) { sleep seconds })
    @command_runner = command_runner
    @executable = executable
    @wait = wait
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
    # A command either answers (its envelope is handed back), is refused
    # (Error, at once — Basecamp's verdict doesn't improve with repetition),
    # or fails without an answer, in which case it is tried again up to
    # ATTEMPTS times before the failure surfaces as a TransientError.
    def json(*arguments)
      result = parsed = nil

      ATTEMPTS.times do |attempt|
        result = run(*arguments, "-j")
        parsed = parse(result.stdout)

        if result.success? && !parsed.nil?
          return unwrap(parsed)
        elsif !transient?(parsed)
          raise Error, "`basecamp #{arguments.join(' ')}` #{outcome(result)}: #{detail(result)}"
        elsif attempt < ATTEMPTS - 1
          @wait.call(RETRY_DELAYS.fetch(attempt))
        end
      end

      raise TransientError, "`basecamp #{arguments.join(' ')}` #{outcome(result)} on all #{ATTEMPTS} attempts: #{detail(result)}"
    end

    def parse(stdout)
      JSON.parse(stdout)
    rescue JSON::ParserError
      nil
    end

    # No envelope at all — the process died before it could answer, or its
    # output was cut off — is the CLI's failure, not Basecamp's answer.
    def transient?(parsed)
      if envelope?(parsed)
        code = parsed["code"].to_s
        TRANSIENT_CODES.include?(code) || (code == "api_error" && parsed["error"].to_s.match?(TRANSIENT_API_ERROR))
      else
        true
      end
    end

    # A successful exit only gets this far when its output didn't parse.
    def outcome(result)
      result.success? ? "returned malformed JSON" : "failed"
    end

    def detail(result)
      if result.success?
        result.stdout.strip[0, 200]
      else
        [ result.stderr.strip, result.stdout.strip, "exit status #{result.exit_status}" ].find { |candidate| !candidate.empty? }
      end
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
      if envelope?(parsed)
        parsed["data"]
      else
        parsed
      end
    end

    def envelope?(parsed)
      parsed.is_a?(Hash) && parsed.key?("ok")
    end

    def profile_flag(profile)
      profile ? [ "--profile", profile ] : []
    end

    def run(*arguments)
      @command_runner.run(@executable, *arguments)
    end
end
