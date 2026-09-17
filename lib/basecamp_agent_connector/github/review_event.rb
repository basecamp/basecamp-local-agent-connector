class BasecampAgentConnector::GitHub::ReviewEvent
  ACTIONABLE_STATES = %w[approved changes_requested commented]

  # The prefix an agent puts on every PR comment and review reply it writes.
  # Agents post under the operator's own GitHub account, so this marker — not
  # the account — is what tells the agent's words from the operator's own.
  AGENT_PREFIX = "🤖"

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

  # The webhook delivers `state` lowercase (`approved`); the REST API returns
  # it uppercase (`APPROVED`). Both collapse to the documented lowercase form,
  # so the gates and the emitted line read the same whichever source built
  # the event.
  def review_state
    review["state"]&.downcase
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

  def commented?
    review_state == "commented"
  end

  # True when this review carries text and every piece of it — the body and
  # each inline comment — is agent-marked. One unmarked line is a person
  # writing, so the whole review is theirs. A review with no text at all is
  # nobody's word and answers false.
  def agent_authored?
    written = ([ review_body ] + comments.map { |comment| comment["body"] }).map { |text| text.to_s.strip }.reject(&:empty?)
    written.any? && written.all? { |text| text.start_with?(AGENT_PREFIX) }
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
