class BasecampAgentConnector::Webhooks
  Registration = Data.define(:project, :id)

  def initialize(basecamp_cli:, logger: $stderr)
    @basecamp_cli = basecamp_cli
    @logger = logger
    @registrations = []
  end

  def register_all(projects:, url:, types:)
    projects.each do |project|
      register(project: project, url: url, types: types)
    end

    @registrations
  end

  def delete_all
    @registrations.each do |registration|
      delete(registration)
    end
  end

  private
    def register(project:, url:, types:)
      webhook = @basecamp_cli.create_webhook(url: url, project: project, types: types)
      @registrations << Registration.new(project: project, id: webhook.fetch("id"))
    rescue BasecampAgentConnector::BasecampCLI::Error => error
      log "failed to register webhook for project #{project}: #{error.message}"
    end

    def delete(registration)
      unless @basecamp_cli.delete_webhook(id: registration.id, project: registration.project)
        log "failed to delete webhook #{registration.id} for project #{registration.project}"
      end
    rescue BasecampAgentConnector::BasecampCLI::Error => error
      log "failed to delete webhook #{registration.id} for project #{registration.project}: #{error.message}"
    end

    def log(message)
      @logger.puts message
    end
end
