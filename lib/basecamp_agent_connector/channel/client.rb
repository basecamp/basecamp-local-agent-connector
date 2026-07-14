# Drives one (operator, agent) Agent Channel connection. The socket is only a
# wake-up and ack path — fire-and-forget — so every (re)connect and every
# wake-up triggers a catch-up read from the durable cursor endpoint. Each
# dispatch is emitted in the shared NDJSON shape, the cursor advances, and the
# dispatch is acked. The socket is injected so the orchestration is testable
# without a live server.
class BasecampAgentConnector::Channel::Client
  def initialize(api:, cursor:, emitter:, socket:, logger: $stderr)
    @api = api
    @cursor = cursor
    @emitter = emitter
    @socket = socket
    @logger = logger
  end

  def start
    @socket.on_open { catch_up }
    @socket.on_message { |message| handle(message) }
    @socket.connect
  end

  # Read everything past the cursor, emit it, and acknowledge — the same rows
  # the stream hints at, so the two can never disagree.
  def catch_up
    @api.dispatches(after: @cursor.position).each do |dispatch|
      @emitter.emit(dispatch)
      @cursor.advance(dispatch.id)
      @api.ack(dispatch.id)
    end
  end

  private
    def handle(message)
      case message["type"]
      when "dispatch"
        catch_up
      when "ping", "welcome", "confirm_subscription"
        # transport chatter — nothing to do
      else
        log "ignored message: #{message["type"]}"
      end
    end

    def log(message)
      @logger.puts message
    end
end
