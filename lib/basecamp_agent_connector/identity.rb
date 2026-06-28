class BasecampAgentConnector::Identity
  attr_reader :id, :email, :name

  def self.resolve(basecamp_cli:)
    identity = authenticated_user(basecamp_cli).fetch("identity")
    new(id: identity.fetch("id"), email: identity["email_address"], name: full_name(identity))
  end

  def self.authenticated_user(basecamp_cli)
    basecamp_cli.me
  rescue BasecampAgentConnector::BasecampCLI::Error
    raise unless basecamp_cli.refresh_auth
    basecamp_cli.me
  end
  private_class_method :authenticated_user

  def self.full_name(identity)
    [ identity["first_name"], identity["last_name"] ].compact.join(" ")
  end
  private_class_method :full_name

  def initialize(id:, email: nil, name: nil)
    @id = id
    @email = email
    @name = name
  end
end
