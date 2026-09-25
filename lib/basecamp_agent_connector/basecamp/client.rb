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

    # How long a rate-limited Basecamp asked to be left alone, in seconds, or
    # nil when it didn't say. The CLI's envelope has no field for the
    # Retry-After it read: the SDK spells it into the hint ("Try again in 30
    # seconds") and the CLI's own 429s into the message ("Rate limited (retry
    # after 30 seconds)"), so read the prose — and a numeric `retry_after`,
    # top-level or in `meta`, should a release ever add one.
    def retry_after
      self.class.retry_after(@envelope) if rate_limited?
    end

    def self.retry_after(envelope)
      meta = envelope["meta"].is_a?(Hash) ? envelope["meta"] : {}
      stated = envelope["retry_after"] || meta["retry_after"] || "#{envelope["error"]} #{envelope["hint"]}"[RETRY_AFTER, 1]
      seconds = Integer(stated, exception: false)
      seconds if seconds&.positive?
    end

    RETRY_AFTER = /(?:retry after|try again in) (\d+) seconds?/i

    # The CLI's remedy for the failure, when it named one.
    def hint
      @envelope["hint"]
    end
  end

  # The CLI never got an answer out of Basecamp — on any of ATTEMPTS tries.
  # Asking again later may well succeed, so a caller that can defer (a webhook
  # redelivery, the next poll) should, rather than read this as a verdict.
  class TransientError < Error; end

  # The credential itself was refused: the token endpoint answered a
  # client_credentials mint with invalid_client (or invalid_grant) — the
  # agent's secret was rotated, or the agent disconnected, in Basecamp. That
  # is not a blip. No retry, no backoff and no restart gets past it; only the
  # operator re-authenticating the profile does. So it is raised once per
  # profile and remembered (see #json): every later call on that profile
  # raises it again without starting the CLI, because the CLI does not
  # remember the refusal itself and every invocation re-mints — which is how
  # one dead secret went to the token endpoint hundreds of times an hour, for
  # hours, until bc3's abuse tracker started answering 429.
  #
  # A TransientError underneath, so a caller that doesn't know the
  # difference defers exactly as it did before: a webhook answers 503, a
  # poller forgets the line for its next tick, nothing records a verdict on a
  # recording nobody could read. What stops the asking is the refusal being
  # remembered here, and what tells the operator is the `on_credential_refused`
  # callback, which the connector answers by shutting down (see Connector#halt).
  class CredentialRefused < TransientError
    attr_reader :profile

    def initialize(message = nil, envelope: nil, profile: nil)
      super(message, envelope: envelope)
      @profile = profile
    end

    # The token endpoint's RFC 6749 error code, as the CLI relays it.
    def reason
      @envelope["error"].to_s[/\binvalid_(?:client|grant)\b/] || code
    end
  end

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

  # A CLI that classifies its own failures says so in its error envelope: a
  # top-level boolean `retryable`, the SDK's Retryable flag surfaced, on every
  # error envelope and never on a success. The field speaks in one direction
  # only. `true` is a positive signal — the CLI knows the failure was its own
  # plight, whatever the code or message — and is retried without consulting
  # the list below. `false` is not a verdict but the absence of that signal:
  # the CLI stamps it on Basecamp's refusals and on every failure nothing
  # classified, which includes the three CLI-local failures the retry loop
  # exists for (a lost keyring probe surfaces as auth_required; a token
  # refresh that lost the race as api_error; bc3's 500 is left unclassified
  # by the SDK). So `false` falls through to the list, which the field can
  # widen but never narrow. That reading also covers the CLI releases before
  # the field, whose envelopes carry only ok/error/code/hint/meta.
  #
  # The list names what the field does not: the code and, for `api_error`,
  # the message. `api_error` is ambiguous: Basecamp's own 4xx verdicts arrive
  # as one, but so do three failures to get an answer at all — a token
  # refresh that lost the keyring race ("token refresh failed: …"), bc3
  # answering 5xx ("Server error (500)" surfaces at once; "Gateway error
  # (502|503|504)" and the generic "API error: 5xx …" are retried inside the
  # SDK for ~3s first and then surface as "request failed after 3 attempts:
  # …", a prefix the SDK puts only on retryable failures), and the CLI's own
  # circuit breaker refusing to ask ("Service temporarily unavailable":
  # file-backed across processes, open for 30s after five consecutive
  # network/5xx failures). A rate limit is transient too, in either spelling
  # (the dedicated code above, or bc3's "rate limit exceeded" body relayed as
  # an api_error): "not now" is no verdict on the recording, and the
  # account-wide budget rolls over in seconds — so a webhook defers to
  # redelivery and a poller to its next (backed-off) tick, rather than
  # recording a drop. A spelling the CLI stamps `retryable: true` needs no
  # entry here; one it leaves at `false` does, until the CLI classifies it.
  TRANSIENT_CODES = %w[auth_required network rate_limit]
  TRANSIENT_API_ERROR = /token refresh|request failed after \d+ attempts?|server error \(500\)|gateway error \(50\d\)|\bAPI error: 5\d\d\b|service temporarily unavailable|rate limit/i

  # Among the auth_required failures, the one that is Basecamp's verdict on
  # the credential rather than the keyring race: an agent profile's
  # client_credentials mint refused ("Minting an agent token was refused
  # (token error: invalid_client)", every CLI release that mints). A person's
  # refresh refused with invalid_grant is deliberately not here: it arrives
  # as a "token refresh failed" api_error, and a refresh that lost the race
  # to a concurrent one — its refresh token rotated out from under it — is
  # refused with exactly that, so it stays transient. A client secret has no
  # rotation race. It is still retried through the client's attempts like any
  # auth_required, so a race loser that fell back to a stale credentials file
  # holding an older secret has two more chances to read the good one; only a
  # refusal on the last attempt counts.
  CREDENTIAL_REFUSAL = /agent token was refused|\binvalid_client\b/i

  # `profile` is the default for every command that doesn't name one: the
  # CLI otherwise resolves BASECAMP_PROFILE ahead of its configured default,
  # so an unflagged call runs as whatever the environment happens to pin.
  #
  # `on_credential_refused` is called with the CredentialRefused the first
  # time a profile's credential is refused, from whichever thread made the
  # call.
  def initialize(command_runner: BasecampAgentConnector::CommandRunner.new, executable: "basecamp",
    profile: nil, wait: ->(seconds) { sleep seconds }, on_credential_refused: nil)
    @command_runner = command_runner
    @executable = executable
    @profile = profile
    @wait = wait
    @on_credential_refused = on_credential_refused
    @refusals = {}
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

  # Every webhook registered on the project, whoever owns it. Read so a startup
  # sweep can recognize the ones a dead run of ours left behind — and leave
  # every other registration alone.
  def webhooks(project:)
    Array json("webhooks", "list", "--project", project.to_s)
  end

  def webhook(id:, project:)
    json "webhooks", "show", id.to_s, "--project", project.to_s
  end

  # Idempotent, unlike create: an answer lost after the flag landed is
  # re-applied unchanged by the next attempt, so the reads' retries are safe.
  def activate_webhook(id:, project:)
    json "webhooks", "update", id.to_s, "--project", project.to_s, "--active"
  end

  private
    # A command either answers (its envelope is handed back), is refused
    # (Error, at once — Basecamp's verdict doesn't improve with repetition),
    # or fails without an answer, in which case it is tried again up to
    # `attempts` times before the failure surfaces as a TransientError.
    # Reads take the default, since re-asking is idempotent; a mutation
    # passes `attempts: 1`, because a lost answer is not a lost request.
    #
    # A profile whose credential was refused is not asked again at all (see
    # CredentialRefused), and a rate limit that says how long to wait ends
    # the attempts at once: re-asking within seconds is exactly what its
    # Retry-After told us not to do, and the caller paces itself off it.
    def json(*arguments, attempts: ATTEMPTS)
      profile = profile_of(arguments)
      raise @refusals[profile] if @refusals.key?(profile)

      result = parsed = refusal = nil
      tried = 0

      attempts.times do |attempt|
        result = run(*arguments, "-j")
        parsed = parse(result.stdout)
        tried = attempt + 1
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
        elsif tried == attempts || told_to_wait?(parsed)
          break
        else
          @wait.call(RETRY_DELAYS.fetch(attempt))
        end
      end

      if credential_refused?(parsed)
        refuse(profile, failure(CredentialRefused, arguments, result, parsed, tried: tried, profile: profile))
      else
        raise failure(TransientError, arguments, result, refusal || parsed, tried: tried)
      end
    end

    # Remembered before the callback runs, so a call racing in from another
    # thread is already refused without the CLI.
    def refuse(profile, error)
      @refusals[profile] ||= error
      @on_credential_refused&.call(error)
      raise error
    end

    def credential_refused?(parsed)
      envelope?(parsed) && parsed["code"] == "auth_required" && parsed["error"].to_s.match?(CREDENTIAL_REFUSAL)
    end

    def told_to_wait?(parsed)
      envelope?(parsed) && !Error.retry_after(parsed).nil? && Error.rate_limited_envelope?(parsed)
    end

    # The profile a command runs as: the one it names, else the client's
    # default — nil being whatever the CLI resolves on its own.
    def profile_of(arguments)
      index = arguments.index("--profile")
      index ? arguments[index + 1] : @profile
    end

    def parse(stdout)
      JSON.parse(stdout)
    rescue JSON::ParserError
      nil
    end

    # The refusal keeps its envelope (when the CLI produced one) so callers
    # can key behavior off the machine-readable code rather than the prose —
    # see Error#code and Error#rate_limited?.
    def failure(kind, arguments, result, parsed, tried: 1, **details)
      attempts_note = " on all #{tried} attempts" if tried > 1
      kind.new "`basecamp #{arguments.join(' ')}` #{outcome(result)}#{attempts_note}: #{detail(result)}",
        envelope: (parsed if envelope?(parsed)), **details
    end

    # No envelope at all — the process died before it could answer, or its
    # output was cut off — is the CLI's failure, not Basecamp's answer. An
    # envelope the CLI stamped retryable is retried on its word alone; any
    # other is classified by its code and message, `retryable: false`
    # included, since that is where the CLI leaves the failures it never
    # classified.
    def transient?(parsed)
      !envelope?(parsed) || parsed["retryable"] == true || listed_transient?(parsed)
    end

    def listed_transient?(parsed)
      code = parsed["code"].to_s
      TRANSIENT_CODES.include?(code) || (code == "api_error" && parsed["error"].to_s.match?(TRANSIENT_API_ERROR))
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
      arguments += [ "--profile", @profile ] unless @profile.nil? || arguments.include?("--profile")
      @command_runner.run(@executable, *arguments)
    end
end
