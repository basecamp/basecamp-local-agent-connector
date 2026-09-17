require "securerandom"

# The GitHub PR review transport, as a self-contained route on the shared server:
# it owns its secret path and HMAC secret, registers a webhook per repo against
# the shared funnel, and turns each signed delivery into a verified, emitted
# review event. Its endpoint + secret are logged so additional repos can be
# registered against the running connector on the fly (one webhook per PR's repo,
# all multiplexed onto this single funnel).
#
# `operator` is the GitHub login whose approvals are actionable; every other
# reviewer's approval is dropped, since an emitted approval lets the dispatched
# agent land the PR. That same login's bare `commented` reviews are dropped as
# the agent's own noise unless `include_self_reviews` says otherwise — see
# `ReviewPipeline`.
class BasecampAgentConnector::GitHub::Bridge
  def initialize(repos:, events:, operator:, github_cli:, emitter:, include_self_reviews: false, logger: $stderr)
    @repos = repos
    @events = events
    @operator = operator
    @github_cli = github_cli
    @emitter = emitter
    @include_self_reviews = include_self_reviews
    @logger = logger
    @path_secret = SecureRandom.hex(16)
    @hmac_secret = SecureRandom.hex(32)
    @webhooks = BasecampAgentConnector::GitHub::Webhooks.new(github_cli: github_cli)
  end

  def path
    "/gh/#{@path_secret}"
  end

  # Paths this bridge owns, for the run registry to record.
  def paths
    [ path ].compact
  end

  # Reaps the hooks abandoned runs left behind, on the repos those runs
  # watched as well as this one's. Returns the repos it could account for.
  def sweep_orphans(runs)
    @webhooks.delete_orphans(repos: @repos | runs.flat_map(&:repos), paths: runs.flat_map(&:paths))
  end

  def register(base_url:)
    endpoint = "#{base_url}#{path}"
    @webhooks.register_all(repos: @repos, url: endpoint, secret: @hmac_secret, events: @events)
    log "Listening for #{@events.join(', ')} on #{@repos.length} repo(s) at #{endpoint}"
    log "To watch another repo on the fly, register a webhook to #{endpoint} (secret #{@hmac_secret})."
    log "Trust: approvals from @#{@operator} only; changes_requested and commented reviews from any reviewer"
    log self_review_note
  end

  # Answers 200 at once (nil, to the server) and verifies off the request
  # thread: GitHub does not redeliver a failed delivery on its own, so there
  # is no verdict worth holding the response for.
  def handler
    lambda do |request|
      Thread.new do
        pipeline.process(body: request.body, signature: request.header("X-Hub-Signature-256"))
      rescue => error
        log "pipeline error: #{error.message}"
      end

      nil
    end
  end

  def teardown
    @webhooks.delete_all
  end

  private
    # The dispatched agent reviews under the operator's own GitHub account, so
    # the operator's bare comment reviews are the agent talking to itself.
    def self_review_note
      if @include_self_reviews
        "Emitting @#{@operator}'s own commented reviews too (--include-self-reviews)"
      else
        "Dropping @#{@operator}'s own commented reviews (the dispatched agent reviews as you); " \
          "--include-self-reviews keeps them"
      end
    end

    def pipeline
      @pipeline ||= BasecampAgentConnector::GitHub::ReviewPipeline.new \
        secret: @hmac_secret,
        operator: @operator,
        include_self_reviews: @include_self_reviews,
        verifier: BasecampAgentConnector::GitHub::ReviewVerifier.new(github_cli: @github_cli),
        emitter: @emitter
    end

    def log(message)
      @logger.puts message
    end
end
