require "json"

class BasecampAgentConnector::Tunnel
  class Error < StandardError; end

  def initialize(port:, command_runner: BasecampAgentConnector::CommandRunner.new, executable: "tailscale")
    @port = port
    @command_runner = command_runner
    @executable = executable
  end

  def start
    result = run("funnel", "--bg", @port.to_s)
    raise Error, "`tailscale funnel` failed: #{result.stderr.strip}" unless result.success?

    public_url
  end

  def stop
    run("funnel", "reset")
  end

  private
    def public_url
      result = run("status", "--json")
      raise Error, "`tailscale status` failed: #{result.stderr.strip}" unless result.success?

      "https://#{dns_name(result.stdout)}"
    end

    def dns_name(status_json)
      JSON.parse(status_json).fetch("Self").fetch("DNSName").chomp(".")
    end

    def run(*arguments)
      @command_runner.run(@executable, *arguments)
    end
end
