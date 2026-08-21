# The polling counterpart to Bridge. Bridge waits for Basecamp to POST an event
# to a public funnel URL; Poller asks Basecamp what has happened since it last
# looked, and hands the answers to the same Pipeline.
#
# It exists because the funnel is the setup's most fragile part: it needs a
# public DNS name and inbound reachability, and neither survives a restricted
# network. On an airplane connection Tailscale never published the node's ts.net
# record, so every webhook registration failed validation — while outbound HTTPS,
# all polling needs, kept working.
#
# It discovers *pointers*, never facts. A mention payload is built from the
# re-fetched recording rather than from the listing that pointed at it, because
# the notifications listing redacts other people's email addresses and a
# recording read does not — the operator check would fail against the listing and
# holds against the fetch. Verifier then re-fetches to corroborate, so the trust
# chain is exactly the one the webhook path uses.
class BasecampAgentConnector::Basecamp::Poller
  # Notification-sourced events are reported as creations. The distinction the
  # webhook draws between a creation and a content change is not recoverable from
  # a notification, and Pipeline treats both as actionable, so the only thing
  # riding on this is the label.
  KINDS_BY_RECORDING_TYPE = {
    "Comment" => "comment_created",
    "Kanban::Card" => "kanban_card_created",
    "Kanban::Step" => "kanban_step_created",
    "Todo" => "todo_created",
    "Message" => "message_created"
  }.freeze

  DEFAULT_KIND = "comment_created"

  CARD_KIND = "kanban_card_created"

  ASSIGNMENT_KIND = "kanban_card_assignment_changed"

  ASSIGNMENT_ACTION = "assignment_changed"

  NOTIFICATIONS = "notifications"
  CARDS = "cards"
  ASSIGNMENTS = "assignments"

  # Cross-source memory, keyed on the recording rather than on the event. The
  # three sources are three ways of noticing the same thing, and they disagree
  # about what an event id is: a watched-column creation is identified by the
  # card, a notification by the notification. One card filed into a watched
  # column also notifies the bot, so without this it emits twice with two
  # different ids, and each copy starts its own agent on the same work.
  RECORDINGS = "recordings"

  def initialize(basecamp_cli:, agent:, state:, watched_columns: [], projects: [], logger: $stderr)
    @basecamp_cli = basecamp_cli
    @agent = agent
    @state = state
    @watched_columns = watched_columns
    @projects = projects
    @logger = logger
  end

  # Everything new since the last round, in webhook payload shape.
  # Watched creations run first so the column copy is the one that survives
  # deduplication. It is the copy that does not depend on the operator having
  # authored anything, which is the whole point of the watched-column trigger —
  # letting a notification copy win would drop a bot-filed card on the floor.
  def payloads
    @staged = {}
    watched_creations + mentioned + assigned
  end

  # Undo everything this round remembered on that payload's behalf. Called when
  # the Verifier could not reach Basecamp to corroborate it: nothing was emitted,
  # so nothing was handled, and the next round has to see it again.
  def rollback(payload)
    Array(@staged&.delete(payload.dig("recording", "id"))).each do |source, id|
      state.forget source, id
    end
  end

  # A first run has no idea what it has already handled, and the surfaces it
  # watches are not empty: the bot carries a backlog of read notifications and
  # the Sentry column holds every card nobody triaged. Seeding marks all of it
  # seen without emitting, so polling starts from now rather than replaying a
  # night's work into a fresh set of agents.
  def seed
    [ [ NOTIFICATIONS, notifications ], [ CARDS, watched_cards ], [ ASSIGNMENTS, assigned_cards ] ].each do |source, records|
      records.each { |record| remember source, record }
    end
  end

  private
    attr_reader :basecamp_cli, :agent, :state, :watched_columns, :projects

    # A record is remembered once it has been decided — emitted, or skipped for a
    # reason that will still hold next round. A record whose fetch failed is left
    # unremembered on purpose: a blip on a bad connection would otherwise drop one
    # of Fernando's mentions silently, and retrying costs a listing entry.
    def mentioned
      unseen(NOTIFICATIONS, notifications).filter_map do |notification|
        next remember(NOTIFICATIONS, notification) unless watched_bucket?(notification["bucket_name"])

        emit(notification_payload(notification))&.tap do |payload|
          remember NOTIFICATIONS, notification
          stage payload, NOTIFICATIONS, notification["id"]
        end
      end
    end

    # `.tap` and not `&.tap`, because a card whose recording was already emitted
    # from another source still has to be remembered here or it is re-listed every
    # round -- and `nil.tap` runs its block, which is what makes that work.
    def watched_creations
      unseen(CARDS, watched_cards).filter_map do |card|
        emit(card_payload(card)).tap do |payload|
          remember CARDS, card
          stage payload, CARDS, card["id"]
        end
      end
    end

    def assigned
      unseen(ASSIGNMENTS, assigned_cards).filter_map do |card|
        next remember(ASSIGNMENTS, card) unless watched_bucket?(card.dig("bucket", "id"), card.dig("bucket", "name"))

        emit assignment_payload(card)
      end
    end

    # The gate every payload passes through, whichever source built it. A
    # recording is emitted once and then never again, across sources and across
    # restarts.
    def emit(payload)
      return nil if payload.nil?

      id = payload.dig("recording", "id")
      return nil if id.nil? || state.seen?(RECORDINGS, id)

      state.record RECORDINGS, id
      stage payload, RECORDINGS, id
      payload
    end

    # Everything this round wrote to state on a payload's behalf, so it can be
    # taken back if the payload never survives verification. Recording an id says
    # the event was handled; that claim is only true once something was emitted.
    def stage(payload, source, id)
      return payload if payload.nil?

      ((@staged ||= {})[payload.dig("recording", "id")] ||= []) << [ source, id ]
      payload
    end

    def notifications
      listing = basecamp_cli.notifications(profile: agent.profile)
      Array(listing["unreads"]) + Array(listing["reads"])
    rescue BasecampAgentConnector::Basecamp::Client::Error => error
      log "could not read notifications: #{error.message}"
      []
    end

    def watched_cards
      watched_columns.flat_map do |watched|
        basecamp_cli.cards_in_column(project: watched.bucket, column: watched.column, profile: agent.profile)
      rescue BasecampAgentConnector::Basecamp::Client::Error => error
        log "could not read column #{watched}: #{error.message}"
        []
      end
    end

    def assigned_cards
      return [] if agent.name.nil?

      basecamp_cli.cards_assigned_to(agent.name, profile: agent.profile)
    rescue BasecampAgentConnector::Basecamp::Client::Error => error
      log "could not read assignments for #{agent.name}: #{error.message}"
      []
    end

    def notification_payload(notification)
      recording = fetch(BasecampAgentConnector::Basecamp::RecordingUrl.from_app_url(notification["app_url"]))
      return nil if recording.nil?

      {
        "id" => notification["id"],
        "kind" => kind_for(recording),
        "created_at" => notification["created_at"],
        "creator" => recording["creator"],
        "recording" => recording
      }
    end

    # The listing already carries everything the watched-column match needs — the
    # creator, the bucket, and the column as `parent` — so this one costs no fetch.
    def card_payload(card)
      {
        "id" => card["id"],
        "kind" => CARD_KIND,
        "created_at" => card["created_at"],
        "creator" => card["creator"],
        "recording" => card
      }
    end

    # A card listing reports who is assigned but never who did the assigning, and
    # the operator check needs the assigner. The card's own audit trail has it.
    # Nothing here needs the card's assignees: Verifier corroborates those against
    # its own fetch, which is the copy that has them.
    def assignment_payload(card)
      history = events(card)
      return nil if history.nil?

      event = history.find { |candidate| assigns_agent?(candidate) }
      return remember(ASSIGNMENTS, card) if event.nil?

      remember ASSIGNMENTS, card

      {
        "id" => event["id"],
        "kind" => ASSIGNMENT_KIND,
        "created_at" => event["created_at"],
        "creator" => event["creator"],
        "details" => event["details"],
        "recording" => card
      }
    end

    def assigns_agent?(event)
      event["action"] == ASSIGNMENT_ACTION &&
        Array(event.dig("details", "added_person_ids")).include?(agent.person_id)
    end

    def events(card)
      basecamp_cli.events(card["app_url"] || card["id"], profile: agent.profile)
    rescue BasecampAgentConnector::Basecamp::Client::Error => error
      log "could not read the history of card #{card['id']}: #{error.message}"
      nil
    end

    def fetch(url)
      return nil if url.nil?

      recording = basecamp_cli.show(url, profile: agent.profile)
      recording.is_a?(Hash) && recording["id"] ? recording : nil
    rescue BasecampAgentConnector::Basecamp::Client::Error => error
      log "could not read #{url}: #{error.message}"
      nil
    end

    # Notifications and assignments are account-wide, so a bot that belongs to a
    # project nobody asked to watch would otherwise trigger on it.
    def watched_bucket?(*identifiers)
      return true if projects.empty?

      identifiers.compact.any? { |identifier| projects.any? { |project| project.to_s == identifier.to_s } }
    end

    def kind_for(recording)
      KINDS_BY_RECORDING_TYPE.fetch(recording["type"], DEFAULT_KIND)
    end

    # A record with no id cannot be remembered — an id of nil stringifies to the
    # same empty key for every such record, so recording one would mark all of
    # them handled forever. They are passed through and left for the round to
    # decide, which is the safe direction: a duplicate costs a wasted fetch, a
    # swallow costs a mention nobody ever sees.
    def unseen(source, records)
      records.reject { |record| record["id"] && state.seen?(source, record["id"]) }
    end

    def remember(source, record)
      state.record source, record["id"] unless record["id"].nil?
      nil
    end

    def log(message)
      @logger.puts message
    end
end
