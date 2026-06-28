$LOAD_PATH.unshift File.expand_path("../lib", __dir__)

require "basecamp_agent_connector"
require "minitest/autorun"
require "json"
require "stringio"

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
      "content" => "<p>Hey #{mention_html("Clawdito")} please take a look</p>",
      "creator" => { "id" => 100, "name" => "Operator", "email_address" => "operator@example.com" },
      "parent" => { "id" => 789, "type" => "Kanban::Card", "app_url" => "https://3.basecamp.com/000/buckets/222/card_tables/cards/789" },
      "bucket" => { "id" => 222, "name" => "BC5 Calendar", "type" => "Project" }
    }.merge(overrides)
  end

  # Basecamp renders the avatar alt/title with the person's full display name
  # while the visible figcaption shows the first name, so default display_name to
  # a full name distinct from the first name the agent is matched on.
  def mention_html(name, person_id: 51177542, display_name: "#{name} Bot (Agent)")
    %(<bc-attachment sgid="SGID" content-type="application/vnd.basecamp.mention"><figure>) +
      %(<img data-avatar-for-person-id="#{person_id}" alt="#{display_name}" title="#{display_name}, Agent" class="avatar">) +
      %(<figcaption>#{name}</figcaption></figure></bc-attachment>)
  end

  def operator_identity
    BasecampAgentConnector::Identity.new(id: 100, email: "operator@example.com")
  end

  def agent_identity(name: "Clawdito")
    BasecampAgentConnector::Identity.new(id: 200, profile: "clawdito", email: "clawdito@example.com", name: name)
  end

  def envelope(data)
    JSON.generate("ok" => true, "data" => data, "summary" => "ok")
  end

  def build_cli(command_runner)
    BasecampAgentConnector::BasecampCLI.new(command_runner: command_runner)
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
