$LOAD_PATH.unshift File.expand_path("../lib", __dir__)

require "basecamp_agent_connector"
require "minitest/autorun"
require "base64"
require "json"
require "openssl"
require "stringio"
require "tmpdir"

class FakeCommandRunner
  attr_reader :commands

  def initialize
    @commands = []
    @stubs = []
  end

  def stub(matcher, stdout: "", stderr: "", exit_status: 0, once: false)
    result = BasecampAgentConnector::CommandRunner::Result.new(stdout: stdout, stderr: stderr, exit_status: exit_status)
    @stubs << { matcher: matcher, result: result, once: once, consumed: false }
  end

  def run(*command)
    @commands << command
    stub = @stubs.find { |candidate| !candidate[:consumed] && matches?(command, candidate[:matcher]) }
    raise "no stub for command: #{command.join(' ')}" if stub.nil?

    stub[:consumed] = true if stub[:once]
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

  # A `kanban_card_created` webhook: a card filed into a column by somebody who
  # is not the operator and who mentions nobody — the shape a robot files.
  def card_created_payload(overrides = {})
    {
      "id" => 99003,
      "kind" => "kanban_card_created",
      "created_at" => "2026-06-28T12:00:00Z",
      "creator" => { "id" => 777, "name" => "MobileBot", "email_address" => "mobilebot@example.com" },
      "recording" => created_card_recording
    }.merge(overrides)
  end

  def created_card_recording(overrides = {})
    sample_recording(
      "id" => 901,
      "type" => "Kanban::Card",
      "title" => "Sentry Crash Report",
      "content" => "<p>Project: hey-ios<br>All issues: HEY-IOS-669</p>",
      "creator" => { "id" => 777, "name" => "MobileBot", "email_address" => "mobilebot@example.com" },
      "parent" => { "id" => 555, "title" => "Sentry", "type" => "Kanban::Column" }
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

  def operator_identity(person_id: nil)
    BasecampAgentConnector::Basecamp::Identity.new(id: 100, email: "operator@example.com", person_id: person_id)
  end

  CIRCLE_ID = 41035616
  TRANSCRIPT_ID = 8317112790

  # A ping notification: one per conversation, pointing at the transcript rather
  # than at any message in it, with the two ids that address it reachable only
  # through `subscription_url`.
  def ping_notification(overrides = {})
    {
      "id" => 3838517425,
      "section" => "pings",
      "type" => "Chat",
      "title" => "Ping",
      "bucket_name" => "Operator + Clawdito",
      "created_at" => "2025-02-11T18:10:14.97Z",
      "updated_at" => "2026-08-26T19:47:06.732Z",
      "app_url" => "https://3.basecamp.com/000/circles/#{CIRCLE_ID}",
      "subscription_url" =>
        "https://3.basecampapi.com/000/buckets/#{CIRCLE_ID}/recordings/#{TRANSCRIPT_ID}/subscription.json"
    }.merge(overrides)
  end

  def ping_line(overrides = {})
    id = overrides["id"] || 10242670010

    {
      "id" => id,
      "type" => "Chat::Lines::RichText",
      "title" => "Ping",
      "content" => "<p>Go ahead. Reply to card 10225414803</p>",
      "created_at" => "2026-08-26T19:47:06.412Z",
      "creator" => { "id" => 100, "name" => "Operator", "email_address" => "operator@example.com" },
      "app_url" => "https://3.basecamp.com/000/circles/#{CIRCLE_ID}@#{id}",
      "url" => "https://3.basecampapi.com/000/buckets/#{CIRCLE_ID}/chats/#{TRANSCRIPT_ID}/lines/#{id}.json",
      "parent" => { "id" => TRANSCRIPT_ID, "type" => "Chat::Transcript", "title" => "Ping" },
      "bucket" => { "id" => CIRCLE_ID, "name" => "Operator + Clawdito", "type" => "Circle" }
    }.merge(overrides)
  end

  def agent_line(overrides = {})
    ping_line({ "creator" => { "id" => 200, "name" => "Clawdito", "email_address" => "clawdito@example.com" } }.merge(overrides))
  end

  def ping_payload(overrides = {})
    {
      "id" => 10242670010,
      "kind" => BasecampAgentConnector::Basecamp::Pings::KIND,
      "created_at" => "2026-08-26T19:47:06.412Z",
      "creator" => { "id" => 100, "name" => "Operator", "email_address" => "operator@example.com" },
      "recording" => ping_line
    }.merge(overrides)
  end

  def ping_circle
    BasecampAgentConnector::Basecamp::Circle.new(id: CIRCLE_ID, transcript: TRANSCRIPT_ID)
  end

  def stub_notifications(runner, notifications)
    runner.stub "notifications list", stdout: envelope("unreads" => notifications, "reads" => [])
  end

  # Matched with the trailing space, or the page-less path is a prefix of every
  # paged one and answers for all of them.
  # Page 1 by default because every reader in a round asks for it by number: the
  # emitter, the adopter and the boost reaper share one read.
  def stub_lines(runner, lines, page: 1)
    runner.stub "api get #{ping_circle.lines_path(page: page)} ", stdout: envelope(lines)
  end

  def stub_boosts(runner, line, booster_ids)
    runner.stub "api get #{ping_circle.boosts_path(line)} ",
      stdout: envelope(booster_ids.map { |id| { "content" => "\u{1F44D}", "booster" => { "id" => id } } })
  end

  # What the Verifier re-fetches: the line's own URL, not the listing it came from.
  def stub_line(runner, line)
    runner.stub "api get #{line['url']} ", stdout: envelope(line)
  end

  def stub_subscribers(runner, ids)
    runner.stub "api get #{ping_circle.subscription_path}",
      stdout: envelope("subscribers" => ids.map { |id| { "id" => id } }, "count" => ids.length)
  end

  def build_pings(runner, state, operator: operator_identity(person_id: 100), agent: agent_identity)
    BasecampAgentConnector::Basecamp::Pings.new \
      basecamp_cli: build_cli(runner), agent: agent, operator: operator, state: state, logger: StringIO.new
  end

  def fresh_state
    BasecampAgentConnector::PollState.new(path: File.join(Dir.mktmpdir, "poll-state.json"))
  end

  def agent_identity(name: "Clawdito", person_id: 200)
    BasecampAgentConnector::Basecamp::Identity.new(id: 200, profile: "clawdito", email: "clawdito@example.com", name: name, person_id: person_id)
  end

  def envelope(data)
    JSON.generate("ok" => true, "data" => data, "summary" => "ok")
  end

  def build_cli(command_runner)
    BasecampAgentConnector::Basecamp::Client.new(command_runner: command_runner)
  end

  def build_github_cli(command_runner)
    BasecampAgentConnector::GitHub::Client.new(command_runner: command_runner)
  end

  # A GitHub `pull_request_review` webhook payload.
  def review_payload(overrides = {})
    {
      "action" => "submitted",
      "review" => review_hash,
      "pull_request" => { "number" => 12, "html_url" => "https://github.com/acme/widgets/pull/12" },
      "repository" => { "full_name" => "acme/widgets" }
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
