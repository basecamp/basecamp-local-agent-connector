class BasecampAgentConnector::Webhooks
  Registration = Data.define(:project, :id)

  def initialize(basecamp_cli:, logger: $stderr, attempts: 3, wait: ->(seconds) { sleep seconds })
    @basecamp_cli = basecamp_cli
    @logger = logger
    @attempts = attempts
    @wait = wait
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
      webhook = create_with_retries(project: project, url: url, types: types)
      @registrations << Registration.new(project: project, id: webhook.fetch("id"))
    rescue BasecampAgentConnector::BasecampCLI::Error => error
      log "failed to register webhook for project #{project} after #{@attempts} attempts: #{error.message}"
    end

    def create_with_retries(project:, url:, types:)
      last_error = nil

      @attempts.times do |attempt|
        return @basecamp_cli.create_webhook(url: url, project: project, types: types)
      rescue BasecampAgentConnector::BasecampCLI::Error => error
        last_error = error
        @wait.call(attempt + 1) unless attempt == @attempts - 1
      end

      raise last_error
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
