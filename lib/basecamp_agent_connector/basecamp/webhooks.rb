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
  def delete_orphans(projects:, paths:)
    return if paths.empty?

    projects.each do |project|
      orphans_in(project, paths).each do |id|
        log "deleting webhook #{id} on project #{project} left by an exited connector"
        delete Registration.new(project: project, id: id)
      end
    end
  end

  # Basecamp switches a webhook off after 10 failed deliveries
  # (bc3 Webhook::DeliveryJob: polynomially_longer backoff, ~4-5h in all) and
  # says nothing: the registration stays listed, `active: false`, and no event
  # reaches this connector again until something turns it back on. From bc3's
  # side that is what a laptop asleep overnight, a funnel path that dropped, or
  # a delivery answered 503 every time all look like. Every registration is
  # re-read and put back: reactivated in place when Basecamp still has it (a
  # deactivation is one flag, and the PUT keeps the id the run recorded),
  # re-registered under a new id when someone deleted it by hand. Returns the
  # registrations that were restored; one that could not be is left as it was
  # and logged, so the next check tries again.
  def restore(url:, types:)
    restored = []

    @registrations.map! do |registration|
      live = restore_registration(registration, url: url, types: types)
      restored << live if live
      live || registration
    end

    restored
  end

  # The registrations as they stand, as a copy: a caller walking them one
  # history read at a time must not be walking the list `restore` rewrites.
  def registrations
    @registrations.dup
  end

  # One registration's recent delivery history, newest first, as Basecamp
  # reports it on the webhook itself: the last attempts (25 of them, verified
  # against production), each carrying the request body it POSTed and the
  # response it got back. That is the only record of a delivery this connector
  # never received, which is what the DeliveryReconciler reads it for. Read
  # one registration at a time, so a slow read holds up nothing already read.
  #
  # Nil when the history could not be read — the call failed, or came back in a
  # shape that is not a list — which is logged, and which a caller must tell
  # apart from an empty history: nothing was learned, so nothing remembered
  # about that history should be let go. The next check reads it again.
  def delivery_history(registration)
    webhook = @basecamp_cli.webhook(id: registration.id, project: registration.project)
    history = webhook["recent_deliveries"] if webhook.is_a?(Hash)

    if history.nil? || history.is_a?(Array)
      Array(history)
    else
      log "could not read the delivery history of webhook #{registration.id} on project #{registration.project}: " \
        "recent_deliveries is not a list"
      nil
    end
  rescue BasecampAgentConnector::Basecamp::Client::Error => error
    log "could not read the delivery history of webhook #{registration.id} on project #{registration.project}: " \
      "#{error.message}"
    nil
  end

  private
    def orphans_in(project, paths)
      @basecamp_cli.webhooks(project: project).filter_map do |webhook|
        webhook["id"] if paths.any? { |path| webhook["payload_url"].to_s.end_with?(path) }
      end
    rescue BasecampAgentConnector::Basecamp::Client::Error => error
      log "could not list webhooks for project #{project}: #{error.message}"
      []
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

    # The live registration when it needed restoring and was; nil when it was
    # fine, or when the attempt failed (logged, retried on the next check).
    def restore_registration(registration, url:, types:)
      case check(registration)
      when :inactive then reactivate(registration)
      when :missing then reregister(registration, url: url, types: types)
      end
    end

    def check(registration)
      webhook = @basecamp_cli.webhook(id: registration.id, project: registration.project)
      webhook["active"] ? :active : :inactive
    rescue BasecampAgentConnector::Basecamp::Client::Error => error
      if error.code == "not_found"
        :missing
      else
        log "could not check webhook #{registration.id} on project #{registration.project}: #{error.message}"
        nil
      end
    end

    def reactivate(registration)
      @basecamp_cli.activate_webhook(id: registration.id, project: registration.project)
      log "#{deactivation_notice(registration)} Reactivated it in place."
      registration
    rescue BasecampAgentConnector::Basecamp::Client::Error => error
      log "#{deactivation_notice(registration)} Failed to reactivate it: #{error.message}; retrying on the next check."
      nil
    end

    def reregister(registration, url:, types:)
      webhook = create_with_retries(project: registration.project, url: url, types: types)
      Registration.new(project: registration.project, id: webhook.fetch("id")).tap do |replacement|
        log "webhook #{registration.id} on project #{registration.project} is gone (deleted outside this connector); " \
          "re-registered it as #{replacement.id}"
      end
    rescue BasecampAgentConnector::Basecamp::Client::Error => error
      log "webhook #{registration.id} on project #{registration.project} is gone (deleted outside this connector) " \
        "and re-registering failed after #{@attempts} attempts: #{error.message}; retrying on the next check"
      nil
    end

    def deactivation_notice(registration)
      "webhook #{registration.id} on project #{registration.project} was DEACTIVATED by Basecamp: bc3 switches a " \
        "webhook off after 10 failed deliveries (~4-5h of retries), which is what an unreachable funnel looks like " \
        "from its side — this machine asleep, the Tailscale funnel path dropped, or every delivery answered 503 " \
        "(check `basecamp auth status`). Nothing has been delivered since it was switched off."
    end

    def delete(registration)
      unless @basecamp_cli.delete_webhook(id: registration.id, project: registration.project)
        log "failed to delete webhook #{registration.id} for project #{registration.project}"
      end
    rescue BasecampAgentConnector::Basecamp::Client::Error => error
      log "failed to delete webhook #{registration.id} for project #{registration.project}: #{error.message}"
    end

    def log(message)
      @logger.puts message
    end
end
