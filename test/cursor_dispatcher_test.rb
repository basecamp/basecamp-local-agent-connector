require "test_helper"
require "webrick"

class CursorDispatcherTest < Minitest::Test
  FIXTURE = File.expand_path("fixtures/cursor_mention_event.ndjson", __dir__)

  def setup
    @log = StringIO.new
    @dispatcher = build_dispatcher
  end

  def test_dispatches_only_events_the_verifier_vouched_for
    assert @dispatcher.dispatchable?(fixture_event)
    refute @dispatcher.dispatchable?(fixture_event("trigger" => { "mentioned" => false, "subscribed" => true }))
  end

  def test_leaves_recordings_that_are_not_a_card_or_its_comment_alone
    message = fixture_event
    message["recording"] = message["recording"].merge("type" => "Message")

    refute @dispatcher.dispatchable?(message)
  end

  # A comment on a message, a document or a to-do is type `Comment` too, and
  # the prompt assumes there is a card to read and reply on.
  def test_leaves_a_comment_whose_parent_is_not_a_card_alone
    on_a_message = fixture_event
    on_a_message["recording"] = on_a_message["recording"].merge(
      "parent" => { "id" => 1, "type" => "Message", "app_url" => "https://example.com/messages/1" })

    refute @dispatcher.dispatchable?(on_a_message)
  end

  def test_dispatches_a_mention_in_the_card_itself
    on_the_card = fixture_event
    on_the_card["recording"] = on_the_card["recording"].merge("type" => "Kanban::Card").except("parent")

    assert @dispatcher.dispatchable?(on_the_card)
  end

  def test_asks_for_a_no_repo_agent
    assert_equal [], @dispatcher.request_body(fixture_event)["repos"]
  end

  def test_hands_the_agent_the_hosted_basecamp_mcp_server
    servers = @dispatcher.request_body(fixture_event)["mcpServers"]

    assert_equal 1, servers.length
    assert_equal "basecamp", servers.first["name"]
    assert_equal "http", servers.first["type"]
    assert_equal "https://mcp.basecamp.com/mcp", servers.first["url"]
    assert_equal "Bearer mcp-token", servers.first.dig("headers", "Authorization")
  end

  def test_prompt_carries_the_card_the_project_and_the_comment
    prompt = @dispatcher.request_body(fixture_event).dig("prompt", "text")

    assert_includes prompt, "https://app.basecamp.com/2914079/buckets/48699913/card_tables/cards/10327460000"
    assert_includes prompt, "48699913"
    assert_includes prompt, "1) Book the room, 2) Send the agenda, 3) Order lunch"
    assert_includes prompt, "create_todo"
    assert_includes prompt, "create_comment"
  end

  # The mention rides in as a `bc-attachment` whose `content` attribute is a
  # whole embedded document. None of that is instruction, and all of it would
  # crowd out the three lines that are.
  def test_prompt_carries_no_mention_markup
    prompt = @dispatcher.request_body(fixture_event).dig("prompt", "text")

    refute_includes prompt, "bc-attachment"
    refute_includes prompt, "&quot;"
  end

  def test_agent_id_is_stable_per_event_so_a_replayed_line_cannot_run_twice
    first = @dispatcher.request_body(fixture_event)["agentId"]

    assert_match(/\Abc-[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/, first)
    assert_equal first, build_dispatcher.request_body(fixture_event)["agentId"]
    refute_equal first, @dispatcher.request_body(fixture_event("event_id" => 999)) ["agentId"]
  end

  def test_posts_the_run_and_polls_it_to_completion
    with_mock_cursor do |port, requests|
      dispatcher = build_dispatcher(api_base: "http://127.0.0.1:#{port}")
      dispatcher.run(StringIO.new(File.read(FIXTURE)))

      assert_equal [ "POST /v1/agents", "GET /v1/agents/bc-mock/runs/run-mock" ], requests.map { |r| "#{r[:method]} #{r[:path]}" }

      posted = JSON.parse(requests.first[:body])
      assert_equal [], posted["repos"]
      assert_equal "https://mcp.basecamp.com/mcp", posted.dig("mcpServers", 0, "url")
      assert_equal "Bearer cursor-key", requests.first[:authorization]
    end
  end

  def test_survives_a_torn_line_without_losing_the_next_event
    with_mock_cursor do |port, requests|
      dispatcher = build_dispatcher(api_base: "http://127.0.0.1:#{port}")
      dispatcher.run(StringIO.new("{\"event_id\": tru\n" + File.read(FIXTURE)))

      assert_equal 2, requests.length
      assert_includes @log.string, "skipping unparseable line"
    end
  end

  # Cursor answers a re-POSTed agentId with 409. That is the idempotency
  # guarantee working, not a failure, and it must not take the watcher's
  # downstream process with it.
  def test_a_replayed_event_is_a_no_op_and_the_stream_keeps_moving
    basecamp = FakeBasecamp.new

    with_mock_cursor(create_status: 409) do |port, requests|
      dispatcher = build_dispatcher(api_base: "http://127.0.0.1:#{port}", basecamp: basecamp)
      dispatcher.run(StringIO.new(File.read(FIXTURE) * 2))

      assert_equal 2, requests.length
      assert_includes @log.string, "dispatched before"
      assert_empty basecamp.comments
    end
  end

  def test_a_failed_run_says_so_on_the_card
    basecamp = FakeBasecamp.new

    with_mock_cursor(run_status: "ERROR") do |port, _requests|
      dispatcher = build_dispatcher(api_base: "http://127.0.0.1:#{port}", basecamp: basecamp)
      dispatcher.run(StringIO.new(File.read(FIXTURE)))
    end

    assert_equal 1, basecamp.comments.length
    assert_equal 10327460000, basecamp.comments.first[:recording]
    assert_equal 48699913, basecamp.comments.first[:project]
    assert_includes basecamp.comments.first[:content], "ERROR"
  end

  def test_a_cursor_outage_says_so_on_the_card_instead_of_stopping
    basecamp = FakeBasecamp.new

    with_mock_cursor(create_status: 500) do |port, _requests|
      dispatcher = build_dispatcher(api_base: "http://127.0.0.1:#{port}", basecamp: basecamp)
      dispatcher.run(StringIO.new(File.read(FIXTURE)))
    end

    assert_includes basecamp.comments.first[:content], "UNDISPATCHED"
  end

  def test_a_finished_run_leaves_the_card_to_the_agent
    basecamp = FakeBasecamp.new

    with_mock_cursor do |port, _requests|
      dispatcher = build_dispatcher(api_base: "http://127.0.0.1:#{port}", basecamp: basecamp)
      dispatcher.run(StringIO.new(File.read(FIXTURE)))
    end

    assert_empty basecamp.comments
  end

  class FakeBasecamp
    attr_reader :comments

    def initialize = @comments = []

    def create_comment(recording:, project:, content:)
      @comments << { recording: recording, project: project, content: content }
    end
  end

  private
    def build_dispatcher(api_base: BasecampAgentConnector::Cursor::Dispatcher::DEFAULT_API_BASE, basecamp: nil)
      BasecampAgentConnector::Cursor::Dispatcher.new \
        api_key: "cursor-key", mcp_token: "mcp-token", api_base: api_base, basecamp: basecamp,
        poll_interval: 0, poll_timeout: 5, log: @log
    end

    def fixture_event(overrides = {})
      JSON.parse(File.read(FIXTURE)).merge(overrides)
    end

    # A stand-in for api.cursor.com shaped by the Cloud Agents OpenAPI spec:
    # the create carries the agent AND its first run, and the run reads back
    # terminal so the poll ends on its first pass.
    def with_mock_cursor(create_status: 200, run_status: "FINISHED")
      requests = []
      port = free_port
      server = WEBrick::HTTPServer.new \
        Port: port, BindAddress: "127.0.0.1", Logger: WEBrick::Log.new(File::NULL), AccessLog: []

      server.mount_proc("/") do |request, response|
        requests << { method: request.request_method, path: request.path,
          body: request.body, authorization: request["Authorization"] }
        response.status = request.request_method == "POST" ? create_status : 200
        response["Content-Type"] = "application/json"
        response.body = JSON.generate(mock_body(request, run_status))
      end

      thread = Thread.new { server.start }
      wait_until_listening(port)

      begin
        yield port, requests
      ensure
        server.shutdown
        thread.join(2)
      end
    end

    def mock_body(request, run_status)
      agent = { "id" => "bc-mock", "status" => "ACTIVE", "env" => {},
        "url" => "https://cursor.com/agents/bc-mock",
        "createdAt" => "2026-09-22T10:31:05Z", "updatedAt" => "2026-09-22T10:31:05Z" }
      run = { "id" => "run-mock", "agentId" => "bc-mock",
        "createdAt" => "2026-09-22T10:31:05Z", "updatedAt" => "2026-09-22T10:31:40Z" }

      if request.request_method == "POST"
        { "agent" => agent, "run" => run.merge("status" => "RUNNING") }
      else
        { "run" => run.merge("status" => run_status, "durationMs" => 35_000,
          "result" => "Created 3 to-dos and commented on the card.") }
      end
    end
end
