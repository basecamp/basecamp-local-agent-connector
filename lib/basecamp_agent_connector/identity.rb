class BasecampAgentConnector::Identity
  attr_reader :profile, :id, :email, :name

  def self.resolve(basecamp_cli:, profile: nil)
    identity = authenticated_user(basecamp_cli, profile).fetch("identity")
    new(profile: profile, id: identity.fetch("id"), email: identity["email_address"], name: identity["first_name"])
  end

  def self.authenticated_user(basecamp_cli, profile)
    basecamp_cli.me(profile: profile)
  rescue BasecampAgentConnector::BasecampCLI::Error
    raise unless basecamp_cli.refresh_auth(profile: profile)
    basecamp_cli.me(profile: profile)
  end
  private_class_method :authenticated_user

  def initialize(id:, profile: nil, email: nil, name: nil)
    @id = id
    @profile = profile
    @email = email
    @name = name
  end

  def same_user_as?(other)
    !email.nil? && !other.email.nil? && email.casecmp?(other.email)
  end
end
