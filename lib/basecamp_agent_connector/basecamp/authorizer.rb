# Decides which Basecamp users may drive the agent. The operator always may;
# each mode extends trust to a further set of authors. Every mode refuses the
# agent's own identity outright — matched by email and by Person id — so the
# agent can never trigger itself no matter how broadly trust is opened (a
# domain the agent's email shares, a project it is a member of).
#
# Assignment events are higher-privilege (assigning the agent a card runs it
# against that card, and the assigner's identity is not corroborated by the
# verifier), so broadened modes apply to mentions only: assignments stay
# operator-only unless `allow_assignments:` opts the mode's authors in.
#
# The pipeline consults `authorizes?` twice: on the claimed webhook payload as
# a cheap pre-filter, and again on the verified event so the decision binds to
# the authoritative creator fetched from Basecamp, not to forgeable POST text.
class BasecampAgentConnector::Basecamp::Authorizer
  DEFAULT_TRUSTED_DOMAIN = "37signals.com"

  def self.build(trust:, operator:, agent:, emails: [], domains: [], allow_assignments: false)
    case trust
    when :operator  then Operator.new(operator: operator, agent: agent, allow_assignments: allow_assignments)
    when :allowlist then Allowlist.new(operator: operator, agent: agent, emails: emails, allow_assignments: allow_assignments)
    when :project   then Project.new(operator: operator, agent: agent, allow_assignments: allow_assignments)
    when :domain    then Domain.new(operator: operator, agent: agent, allow_assignments: allow_assignments,
                       domains: domains.empty? ? [ DEFAULT_TRUSTED_DOMAIN ] : domains)
    else raise ArgumentError, "unknown trust mode #{trust.inspect}"
    end
  end

  def initialize(operator:, agent:, allow_assignments: false)
    @operator = operator
    @agent = agent
    @allow_assignments = allow_assignments
  end

  def authorizes?(event)
    if agent_authored?(event)
      false
    elsif event.assignment_changed? && !@allow_assignments
      operator_authored?(event)
    else
      operator_authored?(event) || authorized_author?(event)
    end
  end

  def description
    "#{mode_description}; assignments: #{@allow_assignments ? "any authorized author" : "operator only"}"
  end

  private
    def operator_authored?(event)
      event.authored_by?(@operator)
    end

    def agent_authored?(event)
      event.authored_by?(@agent) || \
        (!@agent.person_id.nil? && event.creator_id == @agent.person_id)
    end

    # Overridden per mode; the operator alone authorizes in the base case.
    def authorized_author?(event)
      false
    end
end

class BasecampAgentConnector::Basecamp::Authorizer::Operator < BasecampAgentConnector::Basecamp::Authorizer
  private
    def mode_description
      "operator only (#{@operator.email})"
    end
end

class BasecampAgentConnector::Basecamp::Authorizer::Allowlist < BasecampAgentConnector::Basecamp::Authorizer
  def initialize(emails:, **rest)
    super(**rest)
    @emails = emails
  end

  private
    def authorized_author?(event)
      !event.creator_email.nil? && \
        @emails.any? { |email| event.creator_email.casecmp?(email) }
    end

    def mode_description
      "allowlist — operator (#{@operator.email}) + #{@emails.join(", ")}"
    end
end

# Any corroborated author: only project members can post in a project, and the
# verifier confirms the recording really exists with that author, so
# corroboration is the membership proof. Client (external) users are excluded,
# and the exclusion fails *closed*: the corroborated recording must positively
# say the author is not a client (`creator.client == false`). An absent or
# non-boolean flag is treated as untrusted rather than assumed employee, so a
# recording representation that omits it cannot slip a client author through.
class BasecampAgentConnector::Basecamp::Authorizer::Project < BasecampAgentConnector::Basecamp::Authorizer
  private
    def authorized_author?(event)
      !event.creator_id.nil? && event.creator["client"] == false
    end

    def mode_description
      "any corroborated project member (clients excluded)"
    end
end

class BasecampAgentConnector::Basecamp::Authorizer::Domain < BasecampAgentConnector::Basecamp::Authorizer
  def initialize(domains:, **rest)
    super(**rest)
    @domains = domains.map { |domain| domain.downcase.delete_prefix("@") }
  end

  private
    def authorized_author?(event)
      @domains.include?(author_domain(event))
    end

    def author_domain(event)
      event.creator_email.to_s.downcase[/@([^@\s]+)\z/, 1]
    end

    def mode_description
      "any #{@domains.map { |domain| "@#{domain}" }.join(", ")} author"
    end
end
