require "json"

# Turns one signed `pull_request_review` delivery into one emitted review:
# verify the HMAC, filter, dedup, re-fetch the review from the API, emit.
#
# Approvals are the trust boundary: an emitted `approved` review is what lets
# the dispatched agent land the PR, so only the operator's approvals pass.
# `changes_requested` and `commented` reviews are feedback to address, not
# authority to merge, and pass from any reviewer. The reviewer gate runs
# twice — on the claimed delivery as a cheap pre-filter, and again on the
# verified review so the decision binds to the reviewer GitHub actually
# recorded, not to the delivery body.
class BasecampAgentConnector::GitHub::ReviewPipeline
  def initialize(secret:, operator:, verifier:, emitter:, logger: $stderr)
    @secret = secret
    @operator = operator
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

    if actionable?(event)
      if !authorized?(event)
        log_unauthorized(event)
      elsif fresh?(event)
        emit_if_verified(event)
      end
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

    def authorized?(event)
      !event.approved? || event.reviewed_by?(@operator)
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

      if verified.nil?
        log "dropped review #{event.id}: not corroborated by GitHub"
      elsif !authorized?(verified)
        log_unauthorized(verified)
      else
        @emitter.emit(verified)
      end
    end

    def log_unauthorized(event)
      log "dropped review #{event.id}: approved by #{event.reviewer.inspect}, not by the operator (#{@operator})"
    end

    def log(message)
      @logger.puts message
    end
end
