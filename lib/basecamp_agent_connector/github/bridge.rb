require "securerandom"

# The GitHub PR review transport, as a self-contained route on the shared server:
# it owns its secret path and HMAC secret, registers a webhook per repo against
# the shared funnel, and turns each signed delivery into a verified, emitted
# review event. Its endpoint + secret are logged so additional repos can be
# registered against the running connector on the fly (one webhook per PR's repo,
# all multiplexed onto this single funnel).
class BasecampAgentConnector::GitHub::Bridge
  def initialize(repos:, events:, github_cli:, emitter:, logger: $stderr)
    @repos = repos
    @events = events
    @github_cli = github_cli
    @emitter = emitter
    @logger = logger
    @path_secret = SecureRandom.hex(16)
    @hmac_secret = SecureRandom.hex(32)
    @webhooks = BasecampAgentConnector::GitHub::Webhooks.new(github_cli: github_cli)
  end

  def path
    "/gh/#{@path_secret}"
  end

  def register(base_url:)
    endpoint = "#{base_url}#{path}"
    @webhooks.register_all(repos: @repos, url: endpoint, secret: @hmac_secret, events: @events)
    log "Listening for #{@events.join(', ')} on #{@repos.length} repo(s) at #{endpoint}"
    log "To watch another repo on the fly, register a webhook to #{endpoint} (secret #{@hmac_secret})."
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
    def pipeline
      @pipeline ||= BasecampAgentConnector::GitHub::ReviewPipeline.new \
        secret: @hmac_secret,
        verifier: BasecampAgentConnector::GitHub::ReviewVerifier.new(github_cli: @github_cli),
        emitter: @emitter
    end

    def log(message)
      @logger.puts message
    end
end
