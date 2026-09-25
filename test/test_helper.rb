$LOAD_PATH.unshift File.expand_path("../lib", __dir__)

require "basecamp_agent_connector"
require "minitest/autorun"
require "minitest/mock"
require "base64"
require "fileutils"
require "json"
require "openssl"
require "stringio"
require "tmpdir"

# The run registry's default directory is the operator's own
# ~/.config/basecamp-connect/runs, and the records in it are live state: which
# connectors are running on this machine, and which funnel paths a dead one
# abandoned. This suite starts real connectors, so left on that default it
# reads those records, writes one of its own under the test process's pid, and
# — on any sweep that gets as far as succeeding — discards the entry naming a
# dead run's webhooks, which is the only record of them there is. It also makes
# the suite's result depend on whether the operator happens to have a connector
# running: with one alive there is nothing abandoned to sweep and the suite is
# green; the moment one dies without tearing down, five connector tests walk
# into sweep calls their fakes never stubbed. The whole test process gets a
# throwaway directory instead, so no test can reach the real one by forgetting
# to pass a registry.
BasecampAgentConnector::RunRegistry.send :remove_const, :DEFAULT_DIRECTORY
BasecampAgentConnector::RunRegistry::DEFAULT_DIRECTORY = Dir.mktmpdir("basecamp-connect-test-runs")
Minitest.after_run { FileUtils.remove_entry BasecampAgentConnector::RunRegistry::DEFAULT_DIRECTORY, true }

class FakeCommandRunner
  attr_reader :commands

  def initialize
    @commands = []
    @stubs = []
  end

  # A stub answers every matching command until it is used up: `once: true`
  # answers one, `times: n` answers n (a transient failure the client retries
  # through needs one per attempt), and the default answers forever.
  def stub(matcher, stdout: "", stderr: "", exit_status: 0, once: false, times: nil)
    result = BasecampAgentConnector::CommandRunner::Result.new(stdout: stdout, stderr: stderr, exit_status: exit_status)
    @stubs << { matcher: matcher, result: result, remaining: once ? 1 : times }
  end

  def run(*command)
    @commands << command
    stub = @stubs.find { |candidate| candidate[:remaining] != 0 && matches?(command, candidate[:matcher]) }
    raise "no stub for command: #{command.join(' ')}" if stub.nil?

    stub[:remaining] -= 1 unless stub[:remaining].nil?
    stub[:result]
  end

  def commands_matching(pattern)
    @commands.select { |command| command.join(" ").match?(pattern) }
  end

  private
    def matches?(command, matcher)
      joined = command.join(" ")

      if matcher.is_a?(Regexp)
        joined.match?(matcher)
      else
        joined.include?(matcher)
      end
    end
end

module PayloadHelpers
  def sample_payload(overrides = {})
    {
      "id" => 99001,
      "kind" => "comment_created",
      "created_at" => "2026-06-28T12:00:00Z",
      "creator" => { "id" => 100, "name" => "Operator", "email_address" => "operator@example.com" },
      "recording" => sample_recording
    }.merge(overrides)
  end

  def sample_recording(overrides = {})
    {
      "id" => 456,
      "type" => "Comment",
      "title" => "Re: a card",
      "app_url" => "https://3.basecamp.com/000/buckets/222/comments/456",
      "url" => "https://3.basecamp.com/000/buckets/222/comments/456.json",
      "content" => "<p>Hey #{mention_html(person_id: 200)} please take a look</p>",
      "creator" => { "id" => 100, "name" => "Operator", "email_address" => "operator@example.com" },
      "parent" => { "id" => 789, "type" => "Kanban::Card", "app_url" => "https://3.basecamp.com/000/buckets/222/card_tables/cards/789" },
      "bucket" => { "id" => 222, "name" => "BC5 Calendar", "type" => "Project" }
    }.merge(overrides)
  end

  # A `*_assignment_changed` webhook: the operator assigned a card/todo to a
  # person, with the added/removed Person ids in `details`.
  def assignment_payload(overrides = {})
    {
      "id" => 99002,
      "kind" => "kanban_card_assignment_changed",
      "created_at" => "2026-06-28T12:00:00Z",
      "creator" => { "id" => 100, "name" => "Operator", "email_address" => "operator@example.com" },
      "details" => { "added_person_ids" => [ 200 ], "removed_person_ids" => [] },
      "recording" => assigned_recording
    }.merge(overrides)
  end

  def assigned_recording(overrides = {})
    sample_recording(
      "type" => "Kanban::Card",
      "content" => "<p>Fix the date picker, it is off by one.</p>",
      "creator" => { "id" => 777, "name" => "Someone Else", "email_address" => "someone@example.com" },
      "assignees" => [ { "id" => 200, "name" => "Clawdito" } ]
    ).merge(overrides)
  end

  # A `*_active` webhook: a recording that was drafted first and published
  # later. bc3 relays nothing while it is drafted, so the publication is the
  # only delivery the mention ever arrives in.
  def draft_published_payload(overrides = {})
    {
      "id" => 99004,
      "kind" => "message_active",
      "created_at" => "2026-06-28T12:00:00Z",
      "creator" => { "id" => 100, "name" => "Operator", "email_address" => "operator@example.com" },
      "details" => { "notified_recipient_ids" => [ 200 ] },
      "recording" => published_message
    }.merge(overrides)
  end

  def published_message(overrides = {})
    sample_recording(
      "id" => 458,
      "type" => "Message",
      "status" => "active",
      "title" => "Kick off",
      "app_url" => "https://3.basecamp.com/000/buckets/222/messages/458",
      "url" => "https://3.basecamp.com/000/buckets/222/messages/458.json",
      "content" => "<p>Hey #{mention_html(person_id: 200)} let us start</p>",
      "parent" => { "id" => 790, "type" => "Message::Board", "title" => "Message Board",
        "app_url" => "https://3.basecamp.com/000/buckets/222/message_boards/790" }
    ).merge(overrides)
  end

  # A webhook delivers a mention as an unexpanded attachment: just the SGID
  # (which encodes the Person gid) and content-type, with no rendered name.
  def mention_html(person_id:)
    sgid = "#{Base64.strict_encode64("gid://bc3/Person/#{person_id}")}--signature"
    %(<bc-attachment sgid="#{sgid}" content-type="application/vnd.basecamp.mention"></bc-attachment>)
  end

  # The real webhook payload orders the attributes sgid, content, content-type and
  # carries embedded mention markup (full of `>` characters) in the content value.
  def webhook_mention_html(person_id:)
    sgid = "#{Base64.strict_encode64("gid://bc3/Person/#{person_id}")}--signature"
    embedded = %(<bc-mention class=&quot;mentionable-person&quot; gid=&quot;gid://bc3/Person/#{person_id}&quot;><span><img data-avatar-for-person-id=&quot;#{person_id}&quot;>Marie</span></bc-mention>)
    %(<bc-attachment sgid="#{sgid}" content="#{embedded}" content-type="application/vnd.basecamp.mention"></bc-attachment>)
  end

  # A chat line as `basecamp chat messages` / `basecamp chat line` return it:
  # the recording itself, with its Campfire as `parent`. There is no webhook
  # envelope — the ChatPoller synthesizes one via Event.chat_line_payload.
  def chat_line(overrides = {})
    {
      "id" => 91001,
      "type" => "Chat::Lines::RichText",
      "title" => "Hey Clawdito",
      "created_at" => "2026-06-28T12:00:00Z",
      "app_url" => "https://3.basecamp.com/000/buckets/222/chats/333@91001",
      "url" => "https://3.basecamp.com/000/buckets/222/chats/333/lines/91001.json",
      "content" => "<div>Hey #{mention_html(person_id: 200)} please take a look</div>",
      "creator" => { "id" => 100, "name" => "Operator", "email_address" => "operator@example.com" },
      "parent" => { "id" => 333, "type" => "Chat::Transcript", "title" => "Chat", "app_url" => "https://3.basecamp.com/000/buckets/222/chats/333" },
      "bucket" => { "id" => 222, "name" => "BC5 Calendar", "type" => "Project" }
    }.merge(overrides)
  end

  def chat_hash(overrides = {})
    { "id" => 333, "title" => "Chat", "type" => "Chat::Transcript" }.merge(overrides)
  end

  def chat_line_payload(line = chat_line)
    BasecampAgentConnector::Basecamp::Event.chat_line_payload(line)
  end

  # An entry from the agent's received-boosts feed (`/my/boosts.json`): the
  # boost itself plus the booster and the boosted recording (which has no
  # `content` field in this representation). There is no webhook envelope —
  # the BoostPoller synthesizes one via Event.boost_payload.
  # The booster's email arrives redacted: bc3 shows real addresses only to the
  # person themselves or an admin, and the agent fetching its feed is neither.
  # The account Person id is what identifies the booster.
  def received_boost(overrides = {})
    {
      "id" => 88001,
      "content" => "🔥",
      "created_at" => "2026-06-28T12:00:00Z",
      "booster" => { "id" => 100, "name" => "Operator", "email_address" => "o•••••••@•••••••.•••", "client" => false },
      "recording" => boosted_recording
    }.merge(overrides)
  end

  def boosted_recording(overrides = {})
    {
      "id" => 456,
      "type" => "Comment",
      "title" => "Re: a card",
      "app_url" => "https://3.basecamp.com/000/buckets/222/comments/456",
      "url" => "https://3.basecamp.com/000/buckets/222/comments/456.json",
      "creator" => { "id" => 200, "name" => "Clawdito", "email_address" => "clawdito@example.com" },
      "parent" => { "id" => 789, "type" => "Kanban::Card", "app_url" => "https://3.basecamp.com/000/buckets/222/card_tables/cards/789" },
      "bucket" => { "id" => 222, "name" => "BC5 Calendar", "type" => "Project" }
    }.merge(overrides)
  end

  def boost_payload(boost = received_boost)
    BasecampAgentConnector::Basecamp::Event.boost_payload(boost)
  end

  # An entry from a webhook's `recent_deliveries`, as `basecamp webhooks show`
  # returns it: the exact request body Basecamp POSTed, plus the response it
  # got back. `code: 0` with no headers is bc3's record of a delivery whose
  # connection never completed — nothing reached the connector (verified
  # against production).
  def webhook_delivery(body: sample_payload, code: 200, created_at: "2026-06-28T11:59:00Z", id: 70001)
    {
      "id" => id,
      "created_at" => created_at,
      "request" => { "body" => body, "headers" => { "Content-Type" => "application/json" } },
      "response" => { "code" => code, "headers" => (code.zero? ? nil : { "Content-Length" => "0" }), "message" => "" }
    }
  end

  # The `basecamp subscriptions show` envelope: the subscribers of a recording,
  # each a person with an id. The connector matches the agent's Person id here.
  def subscribers_envelope(*person_ids)
    envelope("subscribers" => person_ids.map { |id| { "id" => id, "name" => "Someone" } })
  end

  def operator_identity
    BasecampAgentConnector::Basecamp::Identity.new(id: 100, email: "operator@example.com", person_id: 100)
  end

  def authorizer(trust: :operator, emails: [], domains: [], allow_assignments: false, operator: operator_identity, agent: agent_identity)
    BasecampAgentConnector::Basecamp::Authorizer.build \
      trust: trust, operator: operator, agent: agent,
      emails: emails, domains: domains, allow_assignments: allow_assignments
  end

  def agent_identity(name: "Clawdito", person_id: 200)
    BasecampAgentConnector::Basecamp::Identity.new(id: 200, profile: "clawdito", email: "clawdito@example.com", name: name, person_id: person_id)
  end

  # The CLI's `-j` success envelope. An empty result is not always
  # "data": [] — `chat messages` on a room with no lines omits "data"
  # entirely, returning {"ok": true, "summary": "0 messages"} (verified
  # against production) — which empty_envelope mirrors.
  def envelope(data)
    JSON.generate("ok" => true, "data" => data, "summary" => "ok")
  end

  def empty_envelope(summary = "0 messages")
    JSON.generate("ok" => true, "summary" => summary)
  end

  # The CLI's `-j` failure envelope, printed on stdout with a nonzero exit
  # (verified against production: `basecamp show <missing> -j` exits 2 with
  # {"ok": false, "error": "Resource not found: ...", "code": "not_found"}).
  # A CLI that classifies its own failures adds a boolean `retryable` (pending
  # in basecamp-cli); the default, without one, is the envelope of every
  # release before that.
  def error_envelope(code, error = code.tr("_", " "), **fields)
    JSON.generate({ "ok" => false, "error" => error, "code" => code }.merge(fields.transform_keys(&:to_s)))
  end

  # Stubs a command to fail transiently on every attempt the client makes,
  # so the failure survives its retries.
  def stub_transient_failure(runner, matcher, stdout: error_envelope("auth_required", "Not authenticated for profile:clawdito: credentials not found"), exit_status: 3)
    runner.stub matcher, stdout: stdout, exit_status: exit_status, times: BasecampAgentConnector::Basecamp::Client::ATTEMPTS
  end

  # What the CLI prints when an agent profile's client_credentials mint is
  # refused — the secret rotated, or the agent disconnected, in Basecamp
  # (basecamp-cli internal/auth/agent.go, agentMintRefusal + agentRemedy).
  def agent_refusal_envelope(profile: "clawdito")
    error_envelope "auth_required", "Minting an agent token was refused (token error: invalid_client)", retryable: false,
      hint: "Pipe the agent's client secret in: ... | basecamp auth login --with-client-credentials --client-id bc-agent-7 -P #{profile}"
  end

  # No sleeping between retries in tests; pass `wait:` to observe the delays.
  def build_cli(command_runner, wait: ->(_seconds) { })
    BasecampAgentConnector::Basecamp::Client.new(command_runner: command_runner, wait: wait)
  end

  # A run the registry read as no longer running: what a startup's orphan
  # sweep is handed, and the only record of which webhooks were that run's.
  def dead_run(projects: [], repos: [], paths: [ "/bc5/dead" ], pid: 4_194_303)
    BasecampAgentConnector::RunRegistry::Run.from_json(
      "pid" => pid, "started_at" => "2026-09-01T00:00:00Z", "agent" => "clawdito", "operator" => "jorge",
      "projects" => projects, "repos" => repos, "paths" => paths)
  end

  def build_github_cli(command_runner)
    BasecampAgentConnector::GitHub::Client.new(command_runner: command_runner)
  end

  # A GitHub `pull_request_review` webhook payload. The pull request is the
  # operator's own, which is the case the whole review loop is about: a PR the
  # dispatched agent opened, coming back with feedback on it.
  def review_payload(overrides = {})
    {
      "action" => "submitted",
      "review" => review_hash,
      "pull_request" => pull_request_hash,
      "repository" => { "full_name" => "acme/widgets" }
    }.merge(overrides)
  end

  def pull_request_hash(overrides = {})
    {
      "number" => 12,
      "html_url" => "https://github.com/acme/widgets/pull/12",
      "user" => { "login" => "octocat" }
    }.merge(overrides)
  end

  def review_hash(overrides = {})
    {
      "id" => 7001,
      "state" => "changes_requested",
      "body" => "please fix the naming",
      "user" => { "login" => "octocat" },
      "html_url" => "https://github.com/acme/widgets/pull/12#pullrequestreview-7001"
    }.merge(overrides)
  end

  def sign(body, secret)
    "sha256=" + OpenSSL::HMAC.hexdigest("SHA256", secret, body)
  end

  def free_port
    socket = TCPServer.new("127.0.0.1", 0)
    port = socket.addr[1]
    socket.close
    port
  end

  def wait_until_listening(port)
    20.times do
      TCPSocket.new("127.0.0.1", port).close
      return
    rescue Errno::ECONNREFUSED
      sleep 0.05
    end

    flunk "server never started listening on #{port}"
  end
end

class Minitest::Test
  include PayloadHelpers
end
