# Reads each --project token once, at launch, into the id the whole run
# works by: webhooks, chat discovery and every refresh of it. A URL names its
# bucket, an id names itself, and a name must match exactly one project's
# name exactly. The CLI would also take a case variant or a unique substring,
# but over the connector's life that fuzziness picked the wrong project twice
# (a chat-less "Ops" settling on "Ops East"; a name shared with a project the
# lookup couldn't see), and which project an agent listens to is no place
# for a guess: a near miss stops the launch and names what it nearly matched.
# Resolving once also means a project renamed mid-run, or a namesake created
# later, changes nothing about what the run watches.
module BasecampAgentConnector::Basecamp::Projects
  class Unresolved < StandardError; end

  NEAR_MATCHES = 5

  def self.resolve(tokens, basecamp_cli:)
    listed = nil
    tokens.map { |token| id_in(token) || named(token.to_s, listed ||= basecamp_cli.projects) }
  end

  def self.id_in(token)
    token.to_s[%r{/(?:buckets|projects)/(\d+)}, 1] || token.to_s[/\A\d+\z/]
  end

  def self.named(name, projects)
    exact = projects.select { |project| project["name"] == name }

    if exact.length == 1
      exact.first["id"].to_s
    elsif exact.length > 1
      raise Unresolved, "#{name.inspect} names #{exact.length} projects: #{exact.map { |project| project["id"] }.join(', ')}. " \
        "Pass the one you mean by id or URL."
    else
      raise Unresolved, "No project is named exactly #{name.inspect}#{near(name, projects)}. Pass its exact name, its id, or its URL."
    end
  end

  def self.near(name, projects)
    matches = projects \
      .select { |project| project["name"].to_s.downcase.include?(name.downcase) }
      .first(NEAR_MATCHES)
      .map { |project| "#{project['name']} (#{project['id']})" }

    matches.any? ? "; near matches: #{matches.join(', ')}" : ""
  end
end
