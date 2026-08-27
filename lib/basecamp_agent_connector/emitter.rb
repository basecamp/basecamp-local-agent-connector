require "json"

# One line of JSON per event on STDOUT, which is the whole interface the skill
# consumes.
#
# The lock is there because `connect` emits from two threads: webhook deliveries
# arrive on the server's, and pings are polled on their own. Two `puts` calls
# interleaving would put half of one event inside another, and the reader parses
# a line at a time.
class BasecampAgentConnector::Emitter
  def initialize(output: $stdout)
    @output = output
    @lock = Mutex.new
  end

  def emit(event)
    @lock.synchronize do
      @output.puts JSON.generate(event.to_emitted_hash)
      @output.flush
    end
  end
end
