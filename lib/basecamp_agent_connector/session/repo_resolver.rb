# Which local repo a Basecamp project's work happens in.
#
# `config/project_repos.toml` has always held this mapping, but nothing in Ruby
# read it — resolution was the watching session's job, done by a model that
# could fall back on asking. A connector dispatching on its own has nobody to
# ask, so it reads the table itself and, when nothing matches, declines to
# dispatch rather than guessing at a repo and running an agent in it.
#
# The file is a flat `[mappings]` table of token => path, and Ruby ships no
# TOML parser. Rather than add a dependency for seven lines of key/value, this
# reads exactly that shape and ignores everything else — including any other
# table, so a file that later grows a second section does not silently fold it
# into the mappings.
class BasecampAgentConnector::Session::RepoResolver
  DEFAULT_PATH = File.expand_path("../../../config/project_repos.toml", __dir__)

  TABLE_HEADER = /\A\[(?<name>[^\]]+)\]\s*\z/
  MAPPING = /\A\s*"?(?<token>[^"=\s]+)"?\s*=\s*"(?<path>[^"]*)"\s*\z/
  MAPPINGS_TABLE = "mappings".freeze

  def initialize(path: DEFAULT_PATH, mappings: nil)
    @path = path
    @mappings = mappings
  end

  # The local path for a project name, or nil when nothing matches. Tokens are
  # compared case-insensitively against the whole project name, and the first
  # match wins — the order in the file is the precedence, which is why a more
  # specific token belongs above a more general one.
  def resolve(project_name)
    name = project_name.to_s.downcase
    return nil if name.empty?

    _token, path = mappings.find { |token, _path| name.include?(token) }
    path
  end

  # Token => expanded path, in file order.
  def mappings
    @mappings ||= parse
  end

  def any?
    mappings.any?
  end

  private
    def parse
      return {} unless File.readable?(@path)

      table = nil

      File.readlines(@path).each_with_object({}) do |line, mappings|
        line = line.sub(/\A\s*#.*\z/, "").rstrip
        next if line.empty?

        if (header = line.match(TABLE_HEADER))
          table = header[:name]
        elsif table == MAPPINGS_TABLE && (mapping = line.match(MAPPING))
          mappings[mapping[:token].downcase] = File.expand_path(mapping[:path])
        end
      end
    rescue SystemCallError
      {}
    end
end
