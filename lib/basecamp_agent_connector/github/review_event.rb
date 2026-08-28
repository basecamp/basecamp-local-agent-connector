class BasecampAgentConnector::GitHub::ReviewEvent
  ACTIONABLE_STATES = %w[approved changes_requested commented]

  def self.from_payload(payload)
    new(payload)
  end

  def initialize(payload)
    @payload = payload
  end

  def action
    @payload["action"].to_s
  end

  def review
    @payload["review"] || {}
  end

  def review_id
    review["id"]
  end
  alias_method :id, :review_id

  def review_state
    review["state"]
  end

  def review_body
    review["body"]
  end

  def review_url
    review["html_url"]
  end

  def reviewer
    review.dig("user", "login")
  end

  def pull_request
    @payload["pull_request"] || {}
  end

  def pull_number
    pull_request["number"]
  end

  def repository
    @payload["repository"] || {}
  end

  def repo
    repository["full_name"]
  end

  def comments
    @payload["comments"] || []
  end

  def actionable_action?
    action == "submitted"
  end

  def actionable_state?
    ACTIONABLE_STATES.include?(review_state)
  end

  def approved?
    review_state == "approved"
  end

  # GitHub logins are case-insensitive.
  def reviewed_by?(login)
    !reviewer.nil? && !login.nil? && reviewer.casecmp?(login)
  end

  def to_emitted_hash
    {
      "review_id" => review_id,
      "action" => action,
      "state" => review_state,
      "repo" => repo,
      "pull_number" => pull_number,
      "reviewer" => reviewer,
      "body" => review_body,
      "html_url" => review_url,
      "comments" => comments
    }
  end
end
