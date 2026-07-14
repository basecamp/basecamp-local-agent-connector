$LOAD_PATH.unshift File.expand_path("../lib", __dir__)

require "basecamp_agent_connector"
require "minitest/autorun"
require "base64"
require "json"
require "openssl"
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
  def envelope(data)
    JSON.generate("ok" => true, "data" => data, "summary" => "ok")
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
