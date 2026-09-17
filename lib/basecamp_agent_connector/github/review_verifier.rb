class BasecampAgentConnector::GitHub::ReviewVerifier
  def initialize(github_cli:)
    @github_cli = github_cli
  end

  def verify(event)
    review = fetch_review(event)

    if review
      authoritative_event(event, review)
    end
  end

  private
    def fetch_review(event)
      return nil if event.repo.nil? || event.pull_number.nil? || event.review_id.nil?

      @github_cli.review(repo: event.repo, pull_number: event.pull_number, id: event.review_id)
    rescue BasecampAgentConnector::GitHub::Client::Error
      nil
    end

    def authoritative_event(event, review)
      comments = fetch_comments(event)

      BasecampAgentConnector::GitHub::ReviewEvent.from_payload \
        "action" => event.action,
        "review" => review,
        "pull_request" => event.pull_request,
        "repository" => event.repository,
        "comments" => comments || [],
        "comments_complete" => !comments.nil?
    end

    # A review still travels when its inline comments cannot be read — the body
    # alone is worth emitting — but "GitHub did not answer" and "there are
    # none" are different facts, and a filter that reads the comments has to
    # tell them apart. nil says the list is not authoritative.
    def fetch_comments(event)
      @github_cli.review_comments(repo: event.repo, pull_number: event.pull_number, id: event.review_id)
    rescue BasecampAgentConnector::GitHub::Client::Error
      nil
    end
end
