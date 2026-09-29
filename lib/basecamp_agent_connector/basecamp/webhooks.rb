class BasecampAgentConnector::Basecamp::Webhooks
  # `project` is the project as the operator named it; `project_id` is the one
  # Basecamp registered the webhook on, read off the webhook's own API url
  # (`/buckets/<project id>/webhooks/<id>.json`). Nil for a registration this
  # run did not create, which is only ever deleted.
  Registration = Data.define(:project, :id, :project_id) do
    def initialize(project:, id:, project_id: nil)
      super
    end
  end

  WEBHOOK_PROJECT_ID = %r{/buckets/(\d+)/webhooks/}

  def initialize(basecamp_cli:, logger: $stderr, attempts: 3, wait: ->(seconds) { sleep seconds })
    @basecamp_cli = basecamp_cli
    @logger = logger
    @attempts = attempts
    @wait = wait
    @registrations = []
    @replacing = Set.new
    @replacing_lock = Mutex.new
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
  #
  # A webhook re-registered here is active in Basecamp before its create call
  # answers, so its project stays marked as being replaced (see
  # `recorded_delivery`) until the replacement is recorded.
  def restore(url:, types:)
    restored = []

    @registrations.each_index do |index|
      registration = @registrations[index]
      live = restore_registration(registration, url: url, types: types)

      if live
        @registrations[index] = live
        restored << live
      end
    ensure
      @replacing_lock.synchronize { @replacing.delete(registration.project_id) }
    end

    restored
  end

  # The ids of the projects this run's webhooks are registered on: the only
  # projects a delivery to this run can be about.
  def project_ids
    registrations.filter_map(&:project_id).uniq
  end

  # The event as Basecamp delivered it to one of this run's webhooks on the
  # project: the request body of the delivery of that event id in the
  # webhook's own history, or nil when there is none. bc3 records a delivery,
  # body and all, before it sends it, so a POST Basecamp really made is there
  # when it lands. Anybody else can only name an event Basecamp delivered here,
  # and gets back Basecamp's record of it, not what they sent. The history is
  # the last 25 deliveries. A history Basecamp
  # refuses to show holds nothing; one the CLI could not read at all
  # propagates, since that is no answer. So does not finding the delivery
  # while the project's webhook is being replaced, or while the registrations
  # changed under the lookup: the delivery may have gone to a webhook not yet
  # recorded here, and answered 200 it would never be redelivered.
  def recorded_delivery(event_id, project_id)
    looked_in = registrations

    looked_in.select { |registration| registration.project_id == project_id }.each do |registration|
      recent_deliveries(registration).each do |entry|
        delivery = BasecampAgentConnector::Basecamp::Delivery.from_entry(entry)
        return delivery.body if delivery&.event_id == event_id
      end
    end

    if replacing?(project_id) || registrations != looked_in
      raise BasecampAgentConnector::Basecamp::Client::TransientError,
        "the webhook on project #{project_id} was being re-registered while its delivery history was read"
    end

    nil
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
  # Nil when the history could not be read — the call failed, or came back as
  # something other than a webhook carrying a list — which is logged, and which
  # a caller must tell apart from an empty history: nothing was learned, so
  # nothing remembered about that history should be let go. Only a webhook
  # that is a webhook and simply has no deliveries reads as empty. The next
  # check reads it again.
  def delivery_history(registration)
    webhook = @basecamp_cli.webhook(id: registration.id, project: registration.project)

    if !webhook.is_a?(Hash)
      unreadable_history registration, "Basecamp did not answer with a webhook"
    elsif webhook["recent_deliveries"].nil? || webhook["recent_deliveries"].is_a?(Array)
      Array(webhook["recent_deliveries"])
    else
      unreadable_history registration, "recent_deliveries is not a list"
    end
  rescue BasecampAgentConnector::Basecamp::Client::Error => error
    unreadable_history registration, error.message
  end

  private
    # A webhook with no deliveries yet has delivered nothing. An answer that is
    # not a webhook carrying a list of deliveries says nothing either way, and
    # reading it as empty would answer a real delivery 200 as undelivered, so
    # it is no answer: the route defers with a 503 and Basecamp redelivers.
    def recent_deliveries(registration)
      webhook = @basecamp_cli.webhook(id: registration.id, project: registration.project)
      deliveries = webhook["recent_deliveries"] if webhook.is_a?(Hash)

      if webhook.is_a?(Hash) && (deliveries.nil? || deliveries.is_a?(Array))
        Array(deliveries)
      else
        raise BasecampAgentConnector::Basecamp::Client::TransientError,
          "the delivery history of webhook #{registration.id} on project #{registration.project} came back in a " \
          "shape this connector does not recognize"
      end
    rescue BasecampAgentConnector::Basecamp::Client::TransientError
      raise
    rescue BasecampAgentConnector::Basecamp::Client::Error
      []
    end

    def unreadable_history(registration, reason)
      log "could not read the delivery history of webhook #{registration.id} on project #{registration.project}: " \
        "#{reason}"
      nil
    end

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
      @registrations << registration_of(project, webhook)
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

    # A webhook whose project cannot be read off it still delivers, but the
    # webhook route refuses every event it carries: the delivery is looked for
    # among the webhooks registered on the event's project.
    def registration_of(project, webhook)
      project_id = webhook["url"].to_s[WEBHOOK_PROJECT_ID, 1]&.to_i

      if project_id.nil?
        log "could not tell which project webhook #{webhook["id"]} for project #{project} is registered on " \
          "(its url is #{webhook["url"].inspect}); events from that project will be dropped"
      end

      Registration.new(project: project, id: webhook.fetch("id"), project_id: project_id)
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

    def replacing?(project_id)
      @replacing_lock.synchronize { @replacing.include?(project_id) }
    end

    def reregister(registration, url:, types:)
      @replacing_lock.synchronize { @replacing << registration.project_id } if registration.project_id
      webhook = create_with_retries(project: registration.project, url: url, types: types)
      registration_of(registration.project, webhook).tap do |replacement|
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
