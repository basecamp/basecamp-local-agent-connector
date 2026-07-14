require "json"
require "eventmachine"
require "faye/websocket"

# Wraps a faye-websocket client speaking the Action Cable protocol to the agent
# channel. It authenticates with the connection token on the handshake,
# subscribes to AgentChannel, forwards decoded channel messages to the client,
# and renews the presence lease on an interval. This is the one place that
# touches the live socket, so Channel::Client can be tested against a fake.
class BasecampAgentConnector::Channel::Socket
  CHANNEL = "AgentChannel".freeze
  LEASE_INTERVAL = 15

  def initialize(cable_url:, connection_token:, lease_interval: LEASE_INTERVAL)
    @cable_url = cable_url
    @connection_token = connection_token
    @lease_interval = lease_interval
    @open_handlers = []
    @message_handlers = []
  end

  def on_open(&block)
    @open_handlers << block
  end

  def on_message(&block)
    @message_handlers << block
  end

  def connect
    EM.run do
      @websocket = Faye::WebSocket::Client.new(@cable_url, nil, headers: auth_headers)
      @websocket.on(:open)    { subscribe }
      @websocket.on(:message) { |event| receive(JSON.parse(event.data)) }
      @websocket.on(:close)   { EM.stop }
    end
  end

  private
    def auth_headers
      { "Authorization" => "Agent-Connection #{@connection_token}" }
    end

    def subscribe
      transmit "subscribe", identifier
      renew_lease_periodically
    end

    def receive(frame)
      case frame["type"]
      when "confirm_subscription"
        @open_handlers.each(&:call)
      when "ping", "welcome"
        # transport chatter
      else
        deliver(frame["message"]) if frame["message"]
      end
    end

    def deliver(message)
      @message_handlers.each { |handler| handler.call(message) }
    end

    def renew_lease_periodically
      EM.add_periodic_timer(@lease_interval) { perform("renew_lease") }
    end

    def perform(action, data = {})
      transmit "message", identifier, JSON.generate(data.merge(action: action))
    end

    def transmit(command, identifier, data = nil)
      frame = { command: command, identifier: identifier }
      frame[:data] = data if data
      @websocket.send(JSON.generate(frame))
    end

    def identifier
      JSON.generate(channel: CHANNEL)
    end
end
