# The seam. Everything trusted goes through one Emitter — the Basecamp
# pipeline's and the GitHub review pipeline's verified events both — so this
# wraps that one object rather than teaching each pipeline about sessions.
#
# The STDOUT line is written first and unconditionally. A watching session, if
# anyone is running one, sees exactly what it saw before; `--dispatch session`
# adds a second reader of the same event rather than diverting it. And because
# the line is written before the dispatch is attempted, a dispatch that fails
# cannot also cost the event its only other route out.
class BasecampAgentConnector::Session::DispatchingEmitter
  def initialize(inner:, dispatcher:)
    @inner = inner
    @dispatcher = dispatcher
  end

  def emit(event)
    @inner.emit event
    @dispatcher.dispatch event.to_emitted_hash
  end
end
