require "json"
require "fileutils"

# Persists the catch-up cursor per (agent, operator) so a restarted connector
# resumes exactly where it left off. Stored under the connector's config dir.
class BasecampAgentConnector::Channel::Cursor
  def self.config_dir
    File.join(ENV["HOME"], ".config", "basecamp-connect", "cursors")
  end

  def initialize(agent:, operator:, dir: self.class.config_dir)
    @path = File.join(dir, "#{agent}-#{operator}.json")
  end

  def position
    JSON.parse(File.read(@path))["position"]
  rescue Errno::ENOENT, JSON::ParserError
    0
  end

  def advance(position)
    FileUtils.mkdir_p(File.dirname(@path))
    File.write(@path, JSON.generate(position: position))
  end
end
