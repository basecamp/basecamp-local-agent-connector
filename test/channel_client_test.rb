require "test_helper"

class ChannelClientTest < Minitest::Test
  def setup
    @emitted = []
    @acked = []
    @emitter = FakeEmitter.new(@emitted)
    @cursor = FakeCursor.new
    @socket = FakeSocket.new
  end

  def test_catches_up_on_open_emitting_advancing_and_acking
    api = FakeApi.new(pages: { 0 => [ dispatch(1), dispatch(2) ] })
    client(api).start
    @socket.open!

    assert_equal [ 1, 2 ], @emitted.map(&:id)
    assert_equal 2, @cursor.position
    assert_equal [ 1, 2 ], api.acked
  end

  def test_a_wake_up_triggers_a_catch_up_from_the_current_cursor
    api = FakeApi.new(pages: { 0 => [ dispatch(1) ], 1 => [ dispatch(2) ] })
    client(api).start
    @socket.open!
    assert_equal [ 1 ], @emitted.map(&:id)

    @socket.receive("type" => "dispatch")
    assert_equal [ 1, 2 ], @emitted.map(&:id)
    assert_equal 2, @cursor.position
  end

  def test_ignores_transport_chatter
    api = FakeApi.new(pages: { 0 => [] })
    client(api).start
    @socket.open!

    @socket.receive("type" => "ping")
    @socket.receive("type" => "welcome")

    assert_empty @emitted
  end

  private
    def client(api)
      BasecampAgentConnector::Channel::Client.new \
        api: api, cursor: @cursor, emitter: @emitter, socket: @socket, logger: StringIO.new
    end

    def dispatch(id)
      BasecampAgentConnector::Channel::Dispatch.from_payload("id" => id, "reason" => "mentioned", "event" => { "id" => id })
    end

    class FakeEmitter
      def initialize(sink) = @sink = sink
      def emit(dispatch) = @sink << dispatch
    end

    class FakeCursor
      attr_reader :position
      def initialize = @position = 0
      def advance(position) = @position = position
    end

    class FakeSocket
      def on_open(&block) = @on_open = block
      def on_message(&block) = @on_message = block
      def connect = nil
      def open! = @on_open.call
      def receive(message) = @on_message.call(message)
    end

    class FakeApi
      attr_reader :acked

      def initialize(pages:)
        @pages = pages
        @acked = []
      end

      def dispatches(after:, limit: nil)
        @pages.fetch(after, [])
      end

      def ack(dispatch_id)
        @acked << dispatch_id
      end
    end
end
