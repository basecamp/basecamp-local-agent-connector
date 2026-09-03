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

  # Puts back any of this run's paths the funnel has lost — a `tailscale funnel
  # reset` by another tool, or a serve config that didn't survive tailscaled —
  # and returns the paths it remounted. A path still mounted is left alone.
  def remount_missing
    missing = @paths - mounted_paths
    missing.each { |path| mount(path) }
    missing
  end

  private
    def mounted_paths
      result = run("funnel", "status", "--json")
      raise Error, "`tailscale funnel status` failed: #{result.stderr.strip}" unless result.success?

      handler_paths(result.stdout)
    end

    # The status lists each served host:port under "Web" with its "Handlers"
    # keyed by mount path, and under "AllowFunnel" whether that host is on the
    # public internet at all — a handler still served to the tailnet only is
    # as deaf to Basecamp as no handler, so it counts as unmounted. A status
    # that doesn't parse (nothing configured, or a wording change) reads as
    # nothing mounted: remounting a path that is there is harmless, and not
    # remounting one that isn't is the outage this exists to end.
    def handler_paths(status_json)
      status = JSON.parse(status_json)
      funneled = Hash(status["Web"]).select { |site, _config| Hash(status["AllowFunnel"])[site] }
      funneled.values.flat_map { |config| Hash(config["Handlers"]).keys }
    rescue JSON::ParserError
      []
    end

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
