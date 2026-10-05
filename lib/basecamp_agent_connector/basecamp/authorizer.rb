# Decides which Basecamp users may drive the agent, and in which role.
#
# Two roles. **Operators** are the people whose word authorizes the agent: the
# operator always, plus anyone named with `--allow`. **Participants** are a
# wider set — every author at a domain (`--allow-domain`), or every
# corroborated non-client author (`--allow-project`) — whose requests reach the
# agent but carry no authority of their own. The connector says which on every
# emitted line (`role`); what each role may get the agent to do is the
# watcher's policy, not the bridge's.
#
# Participants trigger by mention and by comment on a thread the agent
# follows. Assignments and boosts are operators' only: an assignment's assigner
# is not corroborated by the verifier, and a boost on the agent's work reads as
# approval, which a participant cannot give. Named operators trigger by
# assignment only when `allow_assignments:` opts them in.
#
# Every rule refuses the agent's own identity outright — matched by email and
# by Person id — so the agent can never trigger itself no matter how broadly
# trust is opened (a domain the agent's email shares, a project it is a member
# of).
#
# The pipeline consults `authorizes?` twice: on the claimed webhook payload as
# a cheap pre-filter, and again on the verified event so the decision — and the
# role emitted — binds to the authoritative creator fetched from Basecamp, not
# to forgeable POST text.
class BasecampAgentConnector::Basecamp::Authorizer
  DEFAULT_TRUSTED_DOMAIN = "37signals.com"

  def self.build(trust:, operator:, agent:, emails: [], domains: [], allow_assignments: false)
    options = { operator: operator, agent: agent, emails: emails, allow_assignments: allow_assignments }

    case trust
    when :operator, :allowlist then new(**options)
    when :project then Project.new(**options)
    when :domain  then Domain.new(**options, domains: domains.empty? ? [ DEFAULT_TRUSTED_DOMAIN ] : domains)
    else raise ArgumentError, "unknown trust mode #{trust.inspect}"
    end
  end

  def initialize(operator:, agent:, emails: [], allow_assignments: false)
    @operator = operator
    @agent = agent
    @emails = emails
    @allow_assignments = allow_assignments
  end

  def authorizes?(event)
    !role(event).nil?
  end

  # :operator, :participant, or nil when no rule admits this event.
  def role(event)
    if agent_authored?(event)
      nil
    elsif operator_authored?(event)
      :operator
    elsif named_operator?(event)
      :operator if !event.assignment_changed? || @allow_assignments
    elsif participant?(event)
      :participant if !participant_only_directive?(event)
    end
  end

  # A participant's assignment of the agent, or boost of its work: admitted
  # author, refused trigger. Worth a diagnostic line when dropped, since the
  # person meant it as a request. An assignment of someone else is not aimed
  # at the agent, whatever the card says, so it is not one of these.
  def refuses_participant_directive?(event)
    !agent_authored?(event) && !operator_authored?(event) && !named_operator?(event) && \
      participant?(event) && (event.assigns?(@agent) || event.boost?)
  end

  def description
    "operators: #{([ @operator.email ] + @emails).join(", ")}; participants: #{participant_description}; " \
      "assignments: #{@allow_assignments ? "operators" : "operator only"}"
  end

  private
    def operator_authored?(event)
      event.authored_by?(@operator)
    end

    def named_operator?(event)
      !event.creator_email.nil? && \
        @emails.any? { |email| event.creator_email.casecmp?(email) }
    end

    def agent_authored?(event)
      event.authored_by?(@agent) || \
        (!@agent.person_id.nil? && event.creator_id == @agent.person_id)
    end

    def participant_only_directive?(event)
      event.assignment_changed? || event.boost?
    end

    # Overridden per participant rule; nobody participates in the base case.
    def participant?(event)
      false
    end

    def participant_description
      "none"
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
    def participant?(event)
      !event.creator_id.nil? && event.creator["client"] == false
    end

    def participant_description
      "any corroborated project member (clients excluded)"
    end
end

class BasecampAgentConnector::Basecamp::Authorizer::Domain < BasecampAgentConnector::Basecamp::Authorizer
  def initialize(domains:, **rest)
    super(**rest)
    @domains = domains.map { |domain| domain.downcase.delete_prefix("@") }
  end

  private
    def participant?(event)
      @domains.include?(author_domain(event))
    end

    def author_domain(event)
      event.creator_email.to_s.downcase[/@([^@\s]+)\z/, 1]
    end

    def participant_description
      "any #{@domains.map { |domain| "@#{domain}" }.join(", ")} author"
    end
end
