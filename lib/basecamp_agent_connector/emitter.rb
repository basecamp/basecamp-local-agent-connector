require "json"

class BasecampAgentConnector::Emitter
  def initialize(output: $stdout)
    @output = output
  end

  def emit(event)
    @output.puts JSON.generate(event.to_emitted_hash)
    @output.flush
  end
end
