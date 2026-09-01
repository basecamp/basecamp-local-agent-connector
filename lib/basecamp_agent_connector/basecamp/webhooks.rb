class BasecampAgentConnector::Basecamp::Webhooks
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

  # Reaps registrations left behind by a connector run that died without
  # tearing down — identified by the funnel paths that run recorded, so
  # ownership is a fact rather than a guess. A path nobody recorded is nobody's
  # business here: it may belong to a live connector, another machine, or an
  # older build, and deleting one of those silently makes it deaf.
  #
  # Returns the projects it could account for. A project whose registrations
  # would not list, or whose orphan would not delete, is not one of them: the
  # webhook is still there, so the record of whose it was has to stay too.
  def delete_orphans(projects:, paths:)
    return projects if paths.empty?

    projects.select { |project| sweep(project, paths) }
  end

  private
    def sweep(project, paths)
      orphans = orphans_in(project, paths)
      return false if orphans.nil?

      orphans.map { |id| delete_orphan(project, id) }.all?
    end

    def delete_orphan(project, id)
      log "deleting webhook #{id} on project #{project} left by an exited connector"
      delete Registration.new(project: project, id: id)
    end

    def orphans_in(project, paths)
      @basecamp_cli.webhooks(project: project).filter_map do |webhook|
        webhook["id"] if paths.any? { |path| webhook["payload_url"].to_s.end_with?(path) }
      end
    rescue BasecampAgentConnector::Basecamp::Client::Error => error
      log "could not list webhooks for project #{project}: #{error.message}"
      nil
    end

    def register(project:, url:, types:)
      webhook = create_with_retries(project: project, url: url, types: types)
      @registrations << Registration.new(project: project, id: webhook.fetch("id"))
    rescue BasecampAgentConnector::Basecamp::Client::Error => error
      log "failed to register webhook for project #{project} after #{@attempts} attempts: #{error.message}"
    end

    def create_with_retries(project:, url:, types:)
      last_error = nil

      @attempts.times do |attempt|
        return @basecamp_cli.create_webhook(url: url, project: project, types: types)
      rescue BasecampAgentConnector::Basecamp::Client::Error => error
        last_error = error
        @wait.call(attempt + 1) unless attempt == @attempts - 1
      end

      raise last_error
    end

    def delete(registration)
      return true if @basecamp_cli.delete_webhook(id: registration.id, project: registration.project)

      log "failed to delete webhook #{registration.id} for project #{registration.project}"
      false
    rescue BasecampAgentConnector::Basecamp::Client::Error => error
      log "failed to delete webhook #{registration.id} for project #{registration.project}: #{error.message}"
      false
    end

    def log(message)
      @logger.puts message
    end
end
