require "json"
require "set"
require "time"

# Recovers the triggers a webhook delivery never delivered. bc3 POSTs each
# event once and retries a delivery it got a non-2xx answer to; a delivery
# whose connection never completed at all — the funnel re-establishing, this
# machine's network dropping for a second — is recorded with
# `response.code: 0` and nothing else ever mentions it. The connector logs
# nothing, because it never received the request. The webhook stays `active`
# (deactivation takes ten failures), the WebhookMonitor's re-check therefore
# finds nothing wrong, and the mention is lost in silence: observed in
# production as one code-0 delivery of a `comment_created` that @mentioned the
# agent, among two dozen neighbours that all recorded 200.
#
# Basecamp keeps the last deliveries on the webhook representation itself
# (25 of them, verified against production), each carrying the exact request
# body it POSTed and the response code it got back. So on the same tick as the
# re-check every registration's history is read, and each delivery that did
# not land in the 2xx range is fed through the same Pipeline the live route
# uses — with the original body, not a reconstruction. That makes a reconciled
# trigger indistinguishable from a delivered one: same refusal of the kinds
# Basecamp never delivers by webhook, same authorizer gate, same corroborating
# re-fetch, same authoritative re-check, same drops (agent authored,
# unauthorized author, still a draft), and the same `event_id`, which is what
# keys the pipeline's per-event suppression. A Basecamp retry landing later, a
# second reconciliation pass, and a delivery still in flight while the history
# is read all converge on that one id, so between them the trigger fires
# exactly once.
#
# Bounded by `lookback`: a webhook reactivated after an outage can carry the
# whole outage in its history, and replaying hours of triggers at once is its
# own kind of failure. A failed delivery older than the window is never
# emitted, and neither is one whose attempt time or recorded body cannot be
# read, since neither can be shown safe to replay: each is named in the log
# instead, once, so the hole is visible and can be handed over by hand.
class BasecampAgentConnector::Basecamp::DeliveryReconciler
  # Wide enough to cover several webhook checks (300s each) and a funnel or
  # network blip, short enough that a webhook reactivated after a night asleep
  # replays the last hour rather than the whole backlog.
  DEFAULT_LOOKBACK = 3600

  DELIVERED_RESPONSE_CODES = (200..299)

  # For a caller with nothing to guard a pass with: every unit runs.
  UNGUARDED = lambda do |&unit|
    unit.call
    true
  end

  # One history entry, read defensively. bc3 renders the entry, but its body
  # embeds what people wrote, and a shape this code did not expect must cost
  # that entry — never the pass, and never the entries behind it.
  Delivery = Data.define(:id, :created_at, :attempted_at, :code, :body) do
    def event_id
      body["id"] if body
    end
  end

  def initialize(webhooks:, pipeline:, lookback: DEFAULT_LOOKBACK, logger: $stderr, clock: -> { Time.now })
    @webhooks = webhooks
    @pipeline = pipeline
    @lookback = lookback
    @logger = logger
    @clock = clock
    @settled_delivery_ids = {}
  end

  # One rule per delivery, first pass or fiftieth: already settled here — skip
  # it; answered 2xx, or its event heard by the pipeline through another
  # delivery — it arrived, so settle it silently; unreadable, or failed outside
  # the window — report the hole and settle it, so the log names it once
  # instead of on every check; failed inside the window — reconcile it.
  #
  # `guard` runs each unit of the pass — one history read, one delivery — and
  # answers whether it did; the first refusal ends the pass. The
  # WebhookMonitor guards with its lock, so a stop waits for the unit in
  # flight, not for every verification left in the pass. Each delivery is its
  # own failure boundary as well: one this code cannot handle is logged and
  # settled, and the ones behind it still run.
  #
  # Settled ids are kept per registration, and only for the deliveries still in
  # its history: one that has scrolled out of the last 25 can never be read
  # again, so remembering it would only grow. A history that could not be read
  # lets go of nothing, or the next read would re-report every hole in it.
  def reconcile(guard: UNGUARDED)
    registrations = @webhooks.registrations
    @settled_delivery_ids.select! { |registration, _| registrations.include?(registration) }

    registrations.each do |registration|
      history = nil
      return unless guard.call { history = @webhooks.delivery_history(registration) }
      next if history.nil?

      settled = settled_ids(registration, history)
      history.each do |entry|
        return unless guard.call { consider(registration, entry, settled) }
      end
    end
  end

  private
    def settled_ids(registration, history)
      ids = history.filter_map { |entry| entry["id"] if entry.is_a?(Hash) }
      @settled_delivery_ids[registration] = @settled_delivery_ids.fetch(registration, Set.new) & ids
    end

    # An entry with no delivery id has nothing to settle it under, so it is
    # named on every check it is still in the history: bc3 has always given
    # one, and a history that stops doing so should be loud about it.
    def consider(registration, entry, settled)
      delivery = read(entry)

      if delivery.nil?
        log "skipped an entry of the delivery history of webhook #{registration.id} on project " \
          "#{registration.project}: it carries no delivery id"
      elsif !settled.include?(delivery.id)
        settled << delivery.id
        settle(registration, delivery, settled)
      end
    rescue => error
      log "could not reconcile delivery #{delivery&.id} of webhook #{registration.id} on project " \
        "#{registration.project}: #{error.class}: #{error.message}; not retried"
    end

    # A delivery whose event the pipeline heard by another delivery is left
    # alone, replayable or not (see Pipeline#heard?, which waits out a
    # verification still in flight so the answer is a verdict). A hole is
    # reported while the pipeline holds its event's id reserved (see
    # Pipeline#unless_heard), so a live delivery of the same event cannot emit
    # between the pipeline answering "not heard" and the log announcing a miss:
    # it waits for the line, then claims the id afresh. A replay needs no such
    # care: `process` claims the id atomically, so an event heard a moment
    # after the check is still suppressed.
    def settle(registration, delivery, settled)
      if delivered?(delivery)
        # it arrived
      elsif delivery.body.nil?
        report_unrecovered registration, delivery, "its recorded request body could not be read"
      elsif (reason = unreplayable(delivery))
        @pipeline.unless_heard(delivery.event_id) { report_unrecovered registration, delivery, reason }
      elsif !@pipeline.heard?(delivery.event_id)
        reconcile_delivery registration, delivery, settled
      end
    end

    def unreplayable(delivery)
      if delivery.attempted_at.nil?
        "its attempt time could not be read, so it cannot be shown to fall inside the #{@lookback}s " \
          "reconciliation window"
      elsif delivery.attempted_at < @clock.call - @lookback
        "older than the #{@lookback}s reconciliation window"
      end
    end

    # Only a 2xx answer proves the delivery landed. A code of 0 is bc3 saying
    # it never got an answer, and a history entry carrying no code at all —
    # a delivery still in flight while this read went out — says the same
    # thing: not known to have landed.
    def delivered?(delivery)
      delivery.code.is_a?(Integer) && DELIVERED_RESPONSE_CODES.cover?(delivery.code)
    end

    # Settled once the pipeline returns, whatever its verdict: emitted, dropped,
    # a duplicate, or not corroborated by Basecamp. That last is what the live
    # route answers 200 to, so bc3 would never redeliver it either, and
    # retrying it here every check would only re-log the same refusal for an
    # hour and then name it a hole. Only a call the CLI could not complete
    # leaves the delivery unsettled: there is no verdict yet, and the next
    # check is this pass's redelivery.
    def reconcile_delivery(registration, delivery, settled)
      log "delivery #{delivery.id} of #{describe(delivery)} on project #{registration.project} never reached this " \
        "connector (#{describe_response(delivery)}), so nothing was heard of it; reconciling it from the webhook's " \
        "delivery history"

      @pipeline.process(delivery.body)
    rescue BasecampAgentConnector::Basecamp::Client::TransientError => error
      settled.delete(delivery.id)
      log "could not corroborate reconciled #{describe(delivery)}: #{error.message}; retried on the next webhook check"
    end

    # Not emitted, but never silent: the event, the project and the recording
    # go in the log, so a trigger that cannot be replayed safely is a hole the
    # operator can see and hand over by hand. It is not recovered *here*; bc3
    # may yet redeliver it on its own, which nothing can rule out, so the log
    # says to check before handing it over rather than promising it never will.
    def report_unrecovered(registration, delivery, reason)
      log "MISSED and NOT recovered: delivery #{delivery.id} of #{describe(delivery)} on project " \
        "#{registration.project} never reached this connector (#{describe_response(delivery)}) at " \
        "#{delivery.created_at}, #{reason}#{recording_note(delivery)}; if it was a trigger and has not reached the " \
        "agent since, hand it to the agent by hand"
    end

    def read(entry)
      if entry.is_a?(Hash) && !entry["id"].nil?
        Delivery.new id: entry["id"], created_at: entry["created_at"], attempted_at: parse_time(entry["created_at"]),
          code: response_code(entry), body: request_body(entry)
      end
    end

    def response_code(entry)
      response = entry["response"]
      response["code"] if response.is_a?(Hash)
    end

    # The body as the live route would have read it. bc3 renders it decoded,
    # but one recorded as a string is parsed exactly as the route parses the
    # raw POST. Anything that does not come out as an event envelope — a hash
    # carrying the event id the pipeline's suppression is keyed on — is
    # unreadable, and reported rather than guessed at.
    def request_body(entry)
      request = entry["request"]
      body = request["body"] if request.is_a?(Hash)
      body = JSON.parse(body) if body.is_a?(String)
      body if body.is_a?(Hash) && !body["id"].nil?
    rescue JSON::ParserError
      nil
    end

    def parse_time(value)
      Time.iso8601(value) if value.is_a?(String)
    rescue ArgumentError
      nil
    end

    def describe(delivery)
      if delivery.body
        "event #{delivery.body["id"]} (#{delivery.body["kind"]})"
      else
        "an unreadable event"
      end
    end

    def describe_response(delivery)
      if delivery.code.is_a?(Integer) && delivery.code.positive?
        "answered HTTP #{delivery.code}"
      else
        "no response: the connection failed"
      end
    end

    def recording_note(delivery)
      recording = delivery.body["recording"] if delivery.body
      app_url = recording["app_url"] if recording.is_a?(Hash)
      " — #{app_url}" if app_url
    end

    def log(message)
      @logger.puts message
    end
end
