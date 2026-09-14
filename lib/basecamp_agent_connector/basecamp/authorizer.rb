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
#
# `authorization` names *which* rule admitted an author — "operator",
# "allowlist:email", "allowlist:person", "domain", "project" — and the
# pipeline stamps that onto the emitted line as `authorized_by`, so a watcher
# handing the event to a worker can tell an operator's request from a
# colleague's without re-deriving the trust decision.
class BasecampAgentConnector::Basecamp::Authorizer
  DEFAULT_TRUSTED_DOMAIN = "37signals.com"

  OPERATOR = "operator"

  def self.build(trust:, operator:, agent:, emails: [], person_ids: [], domains: [], allow_assignments: false)
    case trust
    when :operator  then Operator.new(operator: operator, agent: agent, allow_assignments: allow_assignments)
    when :allowlist then Allowlist.new(operator: operator, agent: agent, emails: emails, person_ids: person_ids, allow_assignments: allow_assignments)
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
    !authorization(event).nil?
  end

  # The rule that admits this event's author, or nil when none does.
  def authorization(event)
    if agent_authored?(event)
      nil
    elsif operator_authored?(event)
      OPERATOR
    elsif event.assignment_changed? && !@allow_assignments
      nil
    else
      author_authorization(event)
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
    def author_authorization(event)
      nil
    end
end

class BasecampAgentConnector::Basecamp::Authorizer::Operator < BasecampAgentConnector::Basecamp::Authorizer
  private
    def mode_description
      "operator only (#{@operator.email})"
    end
end

# Named colleagues, by email or by account Person id. The two keys differ in
# reach: an email is visible only to the author and to account admins (see
# Event#authored_by?), so email entries work only where the corroborating
# profile is an admin. A Person id is visible to every viewer — it is the same
# id space a webhook's `creator.id` and a mention SGID use — so a Person entry
# works from any profile, including the agent's own (`--corroborate-as agent`).
class BasecampAgentConnector::Basecamp::Authorizer::Allowlist < BasecampAgentConnector::Basecamp::Authorizer
  EMAIL = "allowlist:email"
  PERSON = "allowlist:person"

  def initialize(emails: [], person_ids: [], **rest)
    super(**rest)
    @emails = emails
    @person_ids = person_ids.map(&:to_i)
  end

  private
    def author_authorization(event)
      if allowed_person?(event)
        PERSON
      elsif allowed_email?(event)
        EMAIL
      end
    end

    def allowed_person?(event)
      !event.creator_id.nil? && @person_ids.include?(event.creator_id)
    end

    def allowed_email?(event)
      !event.creator_email.nil? && \
        @emails.any? { |email| event.creator_email.casecmp?(email) }
    end

    def mode_description
      allowed = @emails + @person_ids.map { |id| "Person #{id}" }
      "allowlist — operator (#{@operator.email}) + #{allowed.join(", ")}"
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
  PROJECT = "project"

  private
    def author_authorization(event)
      PROJECT if !event.creator_id.nil? && event.creator["client"] == false
    end

    def mode_description
      "any corroborated project member (clients excluded)"
    end
end

class BasecampAgentConnector::Basecamp::Authorizer::Domain < BasecampAgentConnector::Basecamp::Authorizer
  DOMAIN = "domain"

  def initialize(domains:, **rest)
    super(**rest)
    @domains = domains.map { |domain| domain.downcase.delete_prefix("@") }
  end

  private
    def author_authorization(event)
      DOMAIN if @domains.include?(author_domain(event))
    end

    def author_domain(event)
      event.creator_email.to_s.downcase[/@([^@\s]+)\z/, 1]
    end

    def mode_description
      "any #{@domains.map { |domain| "@#{domain}" }.join(", ")} author"
    end
end
