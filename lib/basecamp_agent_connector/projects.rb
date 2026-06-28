class BasecampAgentConnector::Projects
  def initialize(basecamp_cli:)
    @basecamp_cli = basecamp_cli
  end

  def watched(explicit:)
    if explicit.any?
      explicit
    else
      all_identifiers
    end
  end

  private
    def all_identifiers
      @basecamp_cli.projects.map { |project| project.fetch("id") }
    end
end
