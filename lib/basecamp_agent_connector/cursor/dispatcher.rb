require "cgi"
require "digest"
require "json"
require "net/http"
require "uri"

# Turns the connector's NDJSON stream into Cursor cloud agent runs.
#
# The connector can already tell that a mention is real — the Verifier
# re-fetched the recording and matched the agent's Person id before the event
# was ever emitted — but it can only hand the work to a process on this
# machine. This dispatcher is the other option: a no-repo Cursor cloud agent,
# with the hosted Basecamp MCP server as its hands, doing the work in Cursor's
# runtime and replying on the card itself.
#
# Deliberately dumb. It filters, builds one request, and watches the run. Every
# decision about what the work actually is lives in the prompt, because the
# agent is the one holding the card.
class BasecampAgentConnector::Cursor::Dispatcher
  class Error < StandardError; end

  # Cursor's answer to a re-POST of an `agentId` it already has. Not a
  # failure: it is the idempotency guarantee working.
  class AlreadyDispatched < Error; end

  DEFAULT_API_BASE = "https://api.cursor.com"

  MCP_URL = "https://mcp.basecamp.com/mcp"

  # The name the agent sees its tools under. The hosted server's gateway tools
  # are `basecamp_<domain>` / `basecamp_<domain>_write` plus a `basecamp` meta
  # tool, so this name is what the prompt can refer to.
  MCP_SERVER_NAME = "basecamp"

  CARD_TYPE = "Kanban::Card"

  COMMENT_TYPE = "Comment"

  TERMINAL_RUN_STATUSES = [ "FINISHED", "ERROR", "CANCELLED", "EXPIRED" ].freeze

  # Not Cursor's statuses — ours, for the three ways a run can end up
  # unaccounted for: the watch gave up while it was still moving (the run
  # carries on in Cursor), the create never got through, or the watch itself
  # broke.
  TIMED_OUT_STATUS = "TIMED_OUT"

  UNDISPATCHED_STATUS = "UNDISPATCHED"

  UNWATCHED_STATUS = "UNWATCHED"

  DEFAULT_POLL_INTERVAL = 5

  DEFAULT_POLL_TIMEOUT = 600

  def initialize(api_key:, mcp_token:, api_base: DEFAULT_API_BASE, mcp_url: MCP_URL,
    basecamp: nil, poll_interval: DEFAULT_POLL_INTERVAL, poll_timeout: DEFAULT_POLL_TIMEOUT,
    log: $stderr, clock: Time)
    @api_key = api_key
    @mcp_token = mcp_token
    @basecamp = basecamp
    @api_base = api_base.to_s.sub(%r{/\z}, "")
    @mcp_url = mcp_url
    @poll_interval = poll_interval
    @poll_timeout = poll_timeout
    @log = log
    @log_lock = Mutex.new
    @clock = clock
  end

  # Reads NDJSON until the stream closes, then waits for the runs still in
  # flight. A malformed line is logged and skipped rather than fatal: this
  # process sits downstream of a long-running watcher, and one torn line must
  # not take the dispatcher down with it.
  def run(input)
    watches = []

    input.each_line do |line|
      next if line.strip.empty?

      event = begin
        JSON.parse(line)
      rescue JSON::ParserError => error
        warn_line "skipping unparseable line: #{error.message}"
        next
      end

      watches << dispatch(event) if dispatchable?(event)
    end

    watches.compact.each(&:join)
  end

  # True only for an event the Verifier already vouched for. `trigger.mentioned`
  # is its verdict, settled against the re-fetched recording — re-deriving it
  # here from the forgeable content would be a second, weaker answer to a
  # question that is already answered.
  #
  # Beyond that, only a card or a comment ON a card. A comment on a message, a
  # document or a to-do is also type `Comment`, and the prompt this dispatcher
  # writes assumes there is a card to read and reply on, so those stay with the
  # local watcher rather than reaching a cloud agent with the wrong URL.
  def dispatchable?(event)
    return false unless event.dig("trigger", "mentioned")

    case event.dig("recording", "type")
    when CARD_TYPE    then true
    when COMMENT_TYPE then event.dig("recording", "parent", "type") == CARD_TYPE
    else false
    end
  end

  # Returns the thread watching the run it started, or nil when nothing was
  # started. Never raises: this sits downstream of a long-running watcher, and
  # one event's bad day must not cost every later event its dispatch.
  #
  # The POST is synchronous — one round trip, and its answer is where the
  # agent id comes from. The watch is not, because a run can take ten minutes
  # and a reader that stops reading for ten minutes fills the pipe it is
  # reading from, which stalls the connector writing into it.
  def dispatch(event)
    created = post_agent(request_body(event))
    agent_id = created.dig("agent", "id")
    run_id = created.dig("run", "id")
    warn_line "dispatched #{event["event_id"]} -> agent #{agent_id} run #{run_id}"

    Thread.new { watch(event, agent_id, run_id) }
  rescue AlreadyDispatched
    warn_line "event #{event["event_id"]} was dispatched before; leaving that run alone"
    nil
  rescue Error => error
    warn_line "event #{event["event_id"]} could not be dispatched: #{error.message}"
    report_back(event, { "status" => UNDISPATCHED_STATUS })
    nil
  end

  # The whole request, ready to POST. Public because it is the artifact worth
  # reviewing: everything the cloud agent will ever know is in here.
  def request_body(event)
    {
      "prompt" => { "text" => prompt_for(event) },
      "name" => agent_name_for(event),
      "agentId" => agent_id_for(event),
      "repos" => [],
      "mcpServers" => [
        {
          "name" => MCP_SERVER_NAME,
          "type" => "http",
          "url" => @mcp_url,
          "headers" => { "Authorization" => "Bearer #{@mcp_token}" }
        }
      ]
    }
  end

  # A stable, client-supplied id derived from the Basecamp event id, so a
  # replayed line is refused by Cursor with `409 agent_id_conflict` instead of
  # starting the same work twice. The connector re-emits on a re-arm, and
  # in-process bookkeeping would not survive a restart; this survives anything.
  def agent_id_for(event)
    digest = Digest::SHA256.hexdigest("basecamp-agent-connector:event:#{event["event_id"]}")
    "bc-#{digest[0, 8]}-#{digest[8, 4]}-#{digest[12, 4]}-#{digest[16, 4]}-#{digest[20, 12]}"
  end

  private
    # Runs on its own thread, so it swallows nothing silently and raises
    # nothing at all — an exception here would surface only at `join`, long
    # after it could be acted on.
    def watch(event, agent_id, run_id)
      run = await_run(agent_id, run_id)
      report_back(event, run) unless run["status"] == "FINISHED"
      run
    rescue Error => error
      warn_line "lost the watch on run #{run_id}: #{error.message}"
      report_back(event, { "id" => run_id, "status" => UNWATCHED_STATUS })
    end

    def prompt_for(event)
      <<~PROMPT
        You are the Basecamp agent that was just mentioned. #{creator_name(event)} left this
        comment on a Basecamp card and asked you for some to-dos.

        Card: #{card_url(event)}
        Project (bucket) id: #{event.dig("recording", "bucket", "id")}

        The comment, verbatim:
        """
        #{comment_text(event)}
        """

        Do exactly this, using the `#{MCP_SERVER_NAME}` MCP server and nothing else:

        1. Read the card with `basecamp_card_tables` / `get_card` so you know its title
           and which project it lives in.
        2. Find where the to-dos belong: `basecamp_todos` / `list_todolists` in project
           #{event.dig("recording", "bucket", "id")}. Use the list the comment names. If it names none,
           create one named after the card.
        3. Create one to-do per item the comment lists, with `basecamp_todos_write` /
           `create_todo`. Copy the wording from the comment. Do not invent items, reword
           them, merge them, or split them.
        4. Comment back on the card with `basecamp_comments_write` / `create_comment`:
           one short line per to-do you created, each with its URL, and nothing else. If a
           step failed, say which one and why instead.

        Create nothing outside that project. Do not change or complete existing to-dos.
        If the comment lists no actionable items, comment back saying so and stop.
      PROMPT
    end

    def agent_name_for(event)
      title = event.dig("recording", "title").to_s.strip
      title = "Basecamp mention #{event["event_id"]}" if title.empty?
      title[0, 100]
    end

    # Where the reply goes. A mention on a comment points at the comment's
    # parent — the card someone is reading — while a mention in the card's own
    # description is already on the card.
    def card_url(event)
      event.dig("recording", "parent", "app_url") || event.dig("recording", "app_url")
    end

    def creator_name(event)
      event.dig("creator", "name") || "Someone"
    end

    # Basecamp content is rich text, and a mention rides in it as a
    # `bc-attachment` tag whose `content` attribute is a whole embedded
    # document. Feeding that markup to the agent buries the three lines that
    # matter, so the tags come out and the entities are unescaped.
    def comment_text(event)
      html = event.dig("recording", "content").to_s
      text = html.gsub(BasecampAgentConnector::Basecamp::Event::BC_ATTACHMENT_TAG, " ")
      text = text.gsub(%r{</(?:p|div|li|h[1-6])>}i, "\n").gsub(%r{<br\s*/?>}i, "\n")
      text = text.gsub(/<[^>]*>/, "")
      CGI.unescapeHTML(text).gsub(/[ \t]+/, " ").gsub(/\n{3,}/, "\n\n").strip
    end

    def post_agent(body)
      request = Net::HTTP::Post.new(URI.join(@api_base + "/", "v1/agents"))
      request["Content-Type"] = "application/json"
      request.body = JSON.generate(body)

      perform(request)
    end

    # Polls until the run stops moving. Cursor's v1 webhooks are not shipped
    # yet and the SSE stream holds a connection open per event, so a 5s poll is
    # the cheapest thing that is also correct.
    def await_run(agent_id, run_id)
      deadline = @clock.now + @poll_timeout

      loop do
        body = perform(Net::HTTP::Get.new(URI.join(@api_base + "/", "v1/agents/#{agent_id}/runs/#{run_id}")))
        run = body["run"] || body

        return run if TERMINAL_RUN_STATUSES.include?(run["status"])

        if @clock.now >= deadline
          warn_line "run #{run_id} still #{run["status"]} after #{@poll_timeout}s; giving up on the watch"
          return run.merge("status" => TIMED_OUT_STATUS)
        end

        sleep @poll_interval
      end
    end

    # The agent replies for itself when the run finishes — it is the one that
    # knows what it did. This is the only other voice, and it exists because a
    # card that gets mentioned and then goes permanently silent is worse than a
    # duplicate comment. It says what happened and stops there; whether
    # anything was half-created is the card reader's to check.
    def report_back(event, run)
      warn_line "run #{run["id"]} for event #{event["event_id"]} ended #{run["status"]}"
      return if @basecamp.nil?

      @basecamp.create_comment \
        recording: card_id(event),
        project: event.dig("recording", "bucket", "id"),
        content: "I handed this to a Cursor cloud agent and the run ended #{run["status"]}. " \
          "It may have got partway, so check the to-do list before asking again."
    rescue StandardError => error
      warn_line "could not post the fallback comment: #{error.message}"
    end

    def card_id(event)
      event.dig("recording", "parent", "id") || event.dig("recording", "id")
    end

    # Everything that can go wrong on the wire — DNS, connection, TLS, a read
    # timeout, a body that is not the JSON it claims — comes back as this
    # class's own Error, so `dispatch` can contain it per event. A transient
    # Cursor failure must cost one card its run, not the stream its watcher.
    def perform(request)
      request["Authorization"] = "Bearer #{@api_key}"
      request["Accept"] = "application/json"

      uri = request.uri
      response = begin
        Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == "https") { |http| http.request(request) }
      rescue StandardError => error
        raise Error, "Cursor #{request.method} #{uri.path} could not be reached: #{redact(error.message)}"
      end

      unless response.is_a?(Net::HTTPSuccess)
        # The body can carry the token back in an echoed error; redact before
        # it reaches an exception message that will end up in a log.
        detail = "Cursor #{request.method} #{uri.path} failed: #{response.code} #{redact(response.body)}"

        raise AlreadyDispatched, detail if response.is_a?(Net::HTTPConflict)
        raise Error, detail
      end

      begin
        JSON.parse(response.body.to_s.empty? ? "{}" : response.body)
      rescue JSON::ParserError => error
        raise Error, "Cursor #{request.method} #{uri.path} answered #{response.code} with unparseable JSON: #{error.message}"
      end
    end

    def redact(text)
      redacted = text.to_s
      [ @api_key, @mcp_token ].each do |secret|
        redacted = redacted.gsub(secret, "[CREDENTIAL REDACTED]") unless secret.to_s.empty?
      end
      redacted
    end

    # Serialized for the same reason the Emitter serializes: watches run on
    # their own threads, and two interleaved writes would tear a line.
    def warn_line(message)
      @log_lock.synchronize do
        @log.puts "[dispatch-cursor] #{redact(message)}"
        @log.flush
      end
    end
end
