require "json"

class BasecampAgentConnector::Basecamp::Client
  # Basecamp answered, and the answer was no: not found, forbidden, invalid.
  # Asking again cannot change it.
  class Error < StandardError
    def initialize(message = nil, envelope: nil)
      super(message)
      @envelope = envelope.to_h
    end

    # The failure envelope's machine-readable code — "not_found",
    # "rate_limit", "api_error", ... — or nil when the command produced no
    # envelope at all.
    def code
      @envelope["code"]
    end

    # bc3 refuses an over-budget account with 429, and the budget is shared
    # across every CLI process on the account. The CLI's taxonomy reserves
    # the code "rate_limit" for that refusal, but today's binary relays the
    # API's own "rate limit exceeded" body as a generic api_error — so
    # recognize either spelling (kept in step with TRANSIENT_API_ERROR,
    # which classifies both as no-verdict). A caller that can defer should
    # ease off rather than keep asking on its regular cadence; see the
    # pollers' backoff.
    def rate_limited?
      self.class.rate_limited_envelope?(@envelope)
    end

    def self.rate_limited_envelope?(envelope)
      envelope["code"] == "rate_limit" || envelope["error"].to_s.match?(/rate limit/i)
    end
  end

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

  # The CLI's error envelope says outright whether the failure was Basecamp's
  # answer or the CLI's plight: a top-level boolean `retryable`, the SDK's
  # own Retryable flag surfaced. It is on every error envelope the CLI
  # writes (false when the CLI has no positive signal) and never on a
  # success, and when present it decides — the code and message below are
  # not consulted.
  #
  # The list is the fallback for CLIs older than the one that emits the
  # field, whose envelopes carry only ok/error/code/hint/meta. There the
  # code and, for `api_error`, the message are all there is to key on.
  # `api_error` is ambiguous: Basecamp's own 4xx verdicts arrive as one, but
  # so do three failures to get an answer at all — a token refresh that lost
  # the keyring race ("token refresh failed: …"), bc3 answering 5xx ("Server
  # error (500)" surfaces at once; "Gateway error (502|503|504)" and the
  # generic "API error: 5xx …" are retried inside the SDK for ~3s first and
  # then surface as "request failed after 3 attempts: …", a prefix the SDK
  # puts only on retryable failures), and the CLI's own circuit breaker
  # refusing to ask ("Service temporarily unavailable": file-backed across
  # processes, open for 30s after five consecutive network/5xx failures).
  # A rate limit is transient too, in either spelling (the dedicated code
  # above, or bc3's "rate limit exceeded" body relayed as an api_error):
  # "not now" is no verdict on the recording, and the account-wide budget
  # rolls over in seconds — so a webhook defers to redelivery and a poller
  # to its next (backed-off) tick, rather than recording a drop.
  # A new spelling belongs in the CLI's flag, not here.
  TRANSIENT_CODES = %w[auth_required network rate_limit]
  TRANSIENT_API_ERROR = /token refresh|request failed after \d+ attempts?|server error \(500\)|gateway error \(50\d\)|\bAPI error: 5\d\d\b|service temporarily unavailable|rate limit/i

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

  # One attempt: a create whose answer was lost may still have created, and
  # asking again would register a second webhook whose id nobody keeps for
  # teardown. Webhooks#create_with_retries retries the registration.
  def create_webhook(url:, project:, types:)
    json "webhooks", "create", url, "--project", project.to_s, "--types", types, attempts: 1
  end

  def delete_webhook(id:, project:)
    run("webhooks", "delete", id.to_s, "--project", project.to_s).success?
  end

  private
    # A command either answers (its envelope is handed back), is refused
    # (Error, at once — Basecamp's verdict doesn't improve with repetition),
    # or fails without an answer, in which case it is tried again up to
    # `attempts` times before the failure surfaces as a TransientError.
    # Reads take the default, since re-asking is idempotent; a mutation
    # passes `attempts: 1`, because a lost answer is not a lost request.
    def json(*arguments, attempts: ATTEMPTS)
      result = parsed = refusal = nil

      attempts.times do |attempt|
        result = run(*arguments, "-j")
        parsed = parse(result.stdout)
        # Rate-limit evidence survives the retries: under concurrent load
        # the budget refusal and the keyring race co-occur, and a final
        # attempt failing the other way must not erase a refusal an earlier
        # one drew — the pollers pace themselves off it. A later verdict
        # still stands unflagged below: an answered verdict proves the
        # budget answered.
        refusal ||= parsed if envelope?(parsed) && Error.rate_limited_envelope?(parsed)

        if result.success? && !parsed.nil?
          return unwrap(parsed)
        elsif !transient?(parsed)
          raise failure(Error, arguments, result, parsed)
        elsif attempt < attempts - 1
          @wait.call(RETRY_DELAYS.fetch(attempt))
        end
      end

      raise failure(TransientError, arguments, result, refusal || parsed, tried: attempts)
    end

    def parse(stdout)
      JSON.parse(stdout)
    rescue JSON::ParserError
      nil
    end

    # The refusal keeps its envelope (when the CLI produced one) so callers
    # can key behavior off the machine-readable code rather than the prose —
    # see Error#code and Error#rate_limited?.
    def failure(kind, arguments, result, parsed, tried: 1)
      attempts_note = " on all #{tried} attempts" if tried > 1
      kind.new "`basecamp #{arguments.join(' ')}` #{outcome(result)}#{attempts_note}: #{detail(result)}",
        envelope: (parsed if envelope?(parsed))
    end

    # No envelope at all — the process died before it could answer, or its
    # output was cut off — is the CLI's failure, not Basecamp's answer. An
    # envelope that carries `retryable` has classified itself; one from an
    # older CLI is classified by its code and message.
    def transient?(parsed)
      if !envelope?(parsed)
        true
      elsif parsed.key?("retryable")
        parsed["retryable"] == true
      else
        code = parsed["code"].to_s
        TRANSIENT_CODES.include?(code) || (code == "api_error" && parsed["error"].to_s.match?(TRANSIENT_API_ERROR))
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
