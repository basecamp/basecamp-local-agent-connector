class BasecampAgentConnector::GitHub::Webhooks
  Registration = Data.define(:repo, :id)

  def initialize(github_cli:, logger: $stderr, attempts: 3, wait: ->(seconds) { sleep seconds })
    @github_cli = github_cli
    @logger = logger
    @attempts = attempts
    @wait = wait
    @registrations = []
  end

  def register_all(repos:, url:, secret:, events:)
    repos.each do |repo|
      register(repo: repo, url: url, secret: secret, events: events)
    end

    @registrations
  end

  def delete_all
    @registrations.each do |registration|
      delete(registration)
    end
  end

  # The Basecamp side's orphan sweep, for repos: reap hooks pointing at a path
  # a dead run of ours recorded, and touch nothing else.
  def delete_orphans(repos:, paths:)
    return if paths.empty?

    repos.each do |repo|
      orphans_in(repo, paths).each do |id|
        log "deleting webhook #{id} on repo #{repo} left by an exited connector"
        delete Registration.new(repo: repo, id: id)
      end
    end
  end

  private
    def orphans_in(repo, paths)
      @github_cli.webhooks(repo: repo).filter_map do |hook|
        hook["id"] if paths.any? { |path| hook.dig("config", "url").to_s.end_with?(path) }
      end
    rescue BasecampAgentConnector::GitHub::Client::Error => error
      log "could not list webhooks for repo #{repo}: #{error.message}"
      []
    end

    def register(repo:, url:, secret:, events:)
      hook = create_with_retries(repo: repo, url: url, secret: secret, events: events)
      @registrations << Registration.new(repo: repo, id: hook.fetch("id"))
    rescue BasecampAgentConnector::GitHub::Client::Error => error
      log "failed to register webhook for repo #{repo} after #{@attempts} attempts: #{error.message}"
    end

    def create_with_retries(repo:, url:, secret:, events:)
      last_error = nil

      @attempts.times do |attempt|
        return @github_cli.create_webhook(repo: repo, url: url, secret: secret, events: events)
      rescue BasecampAgentConnector::GitHub::Client::Error => error
        last_error = error
        @wait.call(attempt + 1) unless attempt == @attempts - 1
      end

      raise last_error
    end

    def delete(registration)
      unless @github_cli.delete_webhook(repo: registration.repo, id: registration.id)
        log "failed to delete webhook #{registration.id} for repo #{registration.repo}"
      end
    rescue BasecampAgentConnector::GitHub::Client::Error => error
      log "failed to delete webhook #{registration.id} for repo #{registration.repo}: #{error.message}"
    end

    def log(message)
      @logger.puts message
    end
end
