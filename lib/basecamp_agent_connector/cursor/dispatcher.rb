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

  DEFAULT_API_BASE = "https://api.cursor.com"

  MCP_URL = "https://mcp.basecamp.com/mcp"

  # The name the agent sees its tools under. The hosted server's gateway tools
  # are `basecamp_<domain>` / `basecamp_<domain>_write` plus a `basecamp` meta
  # tool, so this name is what the prompt can refer to.
  MCP_SERVER_NAME = "basecamp"

  # Mentions arrive on a comment or on the card itself; anything else (a
  # message, a document, a chat line) is a different job than "put these on a
  # list", so it is left for the local watcher.
  DISPATCHABLE_RECORDING_TYPES = [ "Comment", "Kanban::Card" ].freeze

  TERMINAL_RUN_STATUSES = [ "FINISHED", "ERROR", "CANCELLED", "EXPIRED" ].freeze

  DEFAULT_POLL_INTERVAL = 5

  DEFAULT_POLL_TIMEOUT = 600

  def initialize(api_key:, mcp_token:, api_base: DEFAULT_API_BASE, mcp_url: MCP_URL,
    poll_interval: DEFAULT_POLL_INTERVAL, poll_timeout: DEFAULT_POLL_TIMEOUT, log: $stderr, clock: Time)
    @api_key = api_key
    @mcp_token = mcp_token
    @api_base = api_base.to_s.sub(%r{/\z}, "")
    @mcp_url = mcp_url
    @poll_interval = poll_interval
    @poll_timeout = poll_timeout
    @log = log
    @clock = clock
  end

  # Reads NDJSON until the stream closes. A malformed line is logged and
  # skipped rather than fatal: this process sits downstream of a long-running
  # watcher, and one torn line must not take the dispatcher down with it.
  def run(input)
    input.each_line do |line|
      next if line.strip.empty?

      event = begin
        JSON.parse(line)
      rescue JSON::ParserError => error
        warn_line "skipping unparseable line: #{error.message}"
        next
      end

      dispatch(event) if dispatchable?(event)
    end
  end

  # True only for an event the Verifier already vouched for. `trigger.mentioned`
  # is its verdict, settled against the re-fetched recording — re-deriving it
  # here from the forgeable content would be a second, weaker answer to a
  # question that is already answered.
  def dispatchable?(event)
    return false unless event.dig("trigger", "mentioned")

    DISPATCHABLE_RECORDING_TYPES.include?(event.dig("recording", "type"))
  end

  def dispatch(event)
    created = post_agent(request_body(event))
    agent_id = created.dig("agent", "id")
    run_id = created.dig("run", "id")
    warn_line "dispatched #{event["event_id"]} -> agent #{agent_id} run #{run_id}"

    await_run(agent_id, run_id)
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
        run = perform(Net::HTTP::Get.new(URI.join(@api_base + "/", "v1/agents/#{agent_id}/runs/#{run_id}")))
        status = run.dig("run", "status") || run["status"]

        return run if TERMINAL_RUN_STATUSES.include?(status)

        if @clock.now >= deadline
          warn_line "run #{run_id} still #{status} after #{@poll_timeout}s; giving up on the watch"
          return run
        end

        sleep @poll_interval
      end
    end

    def perform(request)
      request["Authorization"] = "Bearer #{@api_key}"
      request["Accept"] = "application/json"

      uri = request.uri
      response = Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == "https") { |http| http.request(request) }

      # The body can carry the token back in an echoed error; redact before it
      # reaches an exception message that will end up in a log.
      raise Error, "Cursor #{request.method} #{uri.path} failed: #{response.code} #{redact(response.body)}" \
        unless response.is_a?(Net::HTTPSuccess)

      JSON.parse(response.body.to_s.empty? ? "{}" : response.body)
    end

    def redact(text)
      redacted = text.to_s
      [ @api_key, @mcp_token ].each do |secret|
        redacted = redacted.gsub(secret, "[CREDENTIAL REDACTED]") unless secret.to_s.empty?
      end
      redacted
    end

    def warn_line(message)
      @log.puts "[dispatch-cursor] #{redact(message)}"
      @log.flush
    end
end
