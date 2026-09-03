class BasecampAgentConnector::Basecamp::Identity
  attr_reader :profile, :id, :email, :name, :person_id

  def self.resolve(basecamp_cli:, profile: nil)
    identity = authenticated_user(basecamp_cli, profile).fetch("identity")
    new \
      profile: profile,
      id: identity.fetch("id"),
      email: identity["email_address"],
      name: identity["first_name"],
      person_id: account_person_id(basecamp_cli, profile)
  end

  def self.authenticated_user(basecamp_cli, profile)
    basecamp_cli.me(profile: profile)
  rescue BasecampAgentConnector::Basecamp::Client::Error
    raise unless basecamp_cli.refresh_auth(profile: profile)
    basecamp_cli.me(profile: profile)
  end
  private_class_method :authenticated_user

  # `me` returns the global identity id, but a webhook mention encodes the
  # account-scoped Person id; resolve that here so mentions match on a stable id.
  # Every trigger keys on it and every consumer tolerates nil by matching
  # nothing, so an answer without one would start a connector that is deaf
  # with no symptom: refuse it here, where the profile can still be named.
  def self.account_person_id(basecamp_cli, profile)
    person = basecamp_cli.person(profile: profile)
    (person["id"] if person.is_a?(Hash)) || \
      raise(BasecampAgentConnector::Basecamp::Client::Error,
        "`basecamp people show me#{" --profile #{profile}" if profile}` returned no account Person id; is that user a member of the account?")
  end
  private_class_method :account_person_id

  def initialize(id:, profile: nil, email: nil, name: nil, person_id: nil)
    @id = id
    @profile = profile
    @email = email
    @name = name
    @person_id = person_id
  end

  def same_user_as?(other)
    !email.nil? && !other.email.nil? && email.casecmp?(other.email)
  end
end
