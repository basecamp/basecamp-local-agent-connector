require "json"

class BasecampAgentConnector::Emitter
  def initialize(output: $stdout)
    @output = output
    @lock = Mutex.new
  end

  # Serialized: webhook deliveries are processed on their own threads and a
  # poller emits from its poll thread, all into one NDJSON stream — an
  # interleaved write would tear a line and break the watcher.
  def emit(event)
    line = JSON.generate(event.to_emitted_hash)

    @lock.synchronize do
      @output.puts line
      @output.flush
    end
  end
end
