require "json"

class BasecampAgentConnector::Tunnel
  class Error < StandardError; end

  def initialize(port:, paths:, command_runner: BasecampAgentConnector::CommandRunner.new, executable: "tailscale")
    @port = port
    @paths = paths
    @command_runner = command_runner
    @executable = executable
  end

  def start
    @paths.each { |path| mount(path) }
    public_url
  end

  # Unmounts only our own paths: `tailscale funnel reset` would tear down paths
  # other tools mounted on this host's funnel too.
  def stop
    @paths.each { |path| run("funnel", "--set-path", path, "off") }
  end

  private
    # The funnel strips the mount prefix before proxying, so the target has to
    # carry the path or the local server sees every delivery at "/".
    def mount(path)
      result = run("funnel", "--bg", "--set-path", path, "http://127.0.0.1:#{@port}#{path}")
      raise Error, "`tailscale funnel` failed: #{result.stderr.strip}" unless result.success?
    end

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
