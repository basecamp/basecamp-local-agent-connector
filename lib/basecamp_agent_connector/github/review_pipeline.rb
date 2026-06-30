require "json"

class BasecampAgentConnector::GitHub::ReviewPipeline
  def initialize(secret:, verifier:, emitter:, logger: $stderr)
    @secret = secret
    @verifier = verifier
    @emitter = emitter
    @logger = logger
    @seen_review_ids = Set.new
  end

  def process(body:, signature:)
    unless authentic?(body, signature)
      log "rejected delivery: invalid or missing signature"
      return
    end

    event = BasecampAgentConnector::GitHub::ReviewEvent.from_payload(JSON.parse(body))

    if actionable?(event) && fresh?(event)
      emit_if_verified(event)
    end
  rescue JSON::ParserError => error
    log "ignored malformed payload: #{error.message}"
  end

  private
    def authentic?(body, signature)
      BasecampAgentConnector::GitHub::WebhookSignature.valid?(body: body, signature: signature, secret: @secret)
    end

    def actionable?(event)
      event.actionable_action? && event.actionable_state?
    end

    def fresh?(event)
      if @seen_review_ids.include?(event.id)
        false
      else
        @seen_review_ids << event.id
        true
      end
    end

    def emit_if_verified(event)
      verified = @verifier.verify(event)

      if verified
        @emitter.emit(verified)
      else
        log "dropped review #{event.id}: not corroborated by GitHub"
      end
    end

    def log(message)
      @logger.puts message
    end
end
