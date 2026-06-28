class BasecampAgentConnector::Identity
  attr_reader :id, :email, :name

  def self.resolve(basecamp_cli:)
    user = authenticated_user(basecamp_cli)
    new(id: user.fetch("id"), email: user["email_address"], name: user["name"])
  end

  def self.authenticated_user(basecamp_cli)
    basecamp_cli.me
  rescue BasecampAgentConnector::BasecampCLI::Error
    raise unless basecamp_cli.refresh_auth
    basecamp_cli.me
  end
  private_class_method :authenticated_user

  def initialize(id:, email: nil, name: nil)
    @id = id
    @email = email
    @name = name
  end
end
