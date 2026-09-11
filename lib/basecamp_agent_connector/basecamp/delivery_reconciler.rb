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
# trigger indistinguishable from a delivered one: same authorizer gate, same
# corroborating re-fetch, same authoritative re-check, same drops (agent
# authored, unauthorized author, still a draft), and the same `event_id`,
# which is what keys the pipeline's per-event suppression. A Basecamp retry
# landing later, a second reconciliation pass, and a delivery still in flight
# while the history is read all converge on that one id, so between them the
# trigger fires exactly once.
#
# Bounded by `lookback`: a webhook reactivated after an outage can carry the
# whole outage in its history, and replaying hours of triggers at once is its
# own kind of failure. A failed delivery older than the window is never
# emitted — it is named in the log instead, once, with its event and its
# recording, so the hole is visible and can be handed over by hand.
class BasecampAgentConnector::Basecamp::DeliveryReconciler
  # Wide enough to cover several webhook checks (300s each) and a funnel or
  # network blip, short enough that a webhook reactivated after a night asleep
  # replays the last hour rather than the whole backlog.
  DEFAULT_LOOKBACK = 3600

  DELIVERED_RESPONSE_CODES = (200..299)

  def initialize(webhooks:, pipeline:, lookback: DEFAULT_LOOKBACK, logger: $stderr, clock: -> { Time.now })
    @webhooks = webhooks
    @pipeline = pipeline
    @lookback = lookback
    @logger = logger
    @clock = clock
    @settled_delivery_ids = Set.new
  end

  # One rule per delivery, first pass or fiftieth: already settled here — skip
  # it; answered 2xx — it arrived, so settle it silently; failed inside the
  # window — reconcile it; failed outside — report the hole and settle it, so
  # the log names it once instead of on every check. Settled ids accumulate one
  # integer per delivery for the session, small enough to keep unpruned.
  def reconcile
    @webhooks.deliveries.each do |registration, deliveries|
      deliveries.each { |delivery| consider(registration, delivery) }
    end
  end

  private
    def consider(registration, delivery)
      if @settled_delivery_ids.include?(delivery["id"])
        # already handled
      elsif delivered?(delivery)
        @settled_delivery_ids << delivery["id"]
      elsif within_lookback?(delivery)
        reconcile_delivery(registration, delivery)
      else
        report_unrecovered(registration, delivery)
      end
    end

    # Only a 2xx answer proves the delivery landed. A code of 0 is bc3 saying
    # it never got an answer, and a history entry carrying no code at all —
    # a delivery still in flight while this read went out — says the same
    # thing: not known to have landed. Both are offered to the pipeline, whose
    # suppression settles the in-flight case (the claim waits for the live
    # verdict and then finds the id seen).
    def delivered?(delivery)
      code = delivery.dig("response", "code")
      code.is_a?(Integer) && DELIVERED_RESPONSE_CODES.cover?(code)
    end

    # Fail toward reconciling: a delivery whose timestamp is missing or
    # unreadable counts as inside the window, since a needless re-offer is
    # deduped away while a dropped mention is gone for good. Comparing
    # Basecamp's timestamps against the local clock assumes NTP-grade sync;
    # skew shifts the boundary by its own magnitude.
    def within_lookback?(delivery)
      attempted_at = parse_time(delivery["created_at"])
      attempted_at.nil? || attempted_at >= @clock.call - @lookback
    end

    def parse_time(value)
      Time.iso8601(value.to_s)
    rescue ArgumentError
      nil
    end

    # Settled means the pipeline reached a verdict (emitted, dropped, ignored,
    # or suppressed as a duplicate). A body Basecamp would not corroborate is
    # unsettled again, so a later check retries it while the recording may yet
    # reappear — exactly as a redelivery would be re-verified. A call the CLI
    # could not complete is unsettled the same way: the next check is this
    # pass's redelivery. A pipeline exception leaves it settled, since
    # retrying a bug every check would only repeat it.
    def reconcile_delivery(registration, delivery)
      log "delivery #{delivery["id"]} of #{describe(delivery)} on project #{registration.project} never reached this " \
        "connector (#{describe_response(delivery)}), so nothing was heard of it; reconciling it from the webhook's " \
        "delivery history"

      @settled_delivery_ids << delivery["id"]
      @settled_delivery_ids.delete(delivery["id"]) unless @pipeline.process(body(delivery))
    rescue BasecampAgentConnector::Basecamp::Client::TransientError => error
      @settled_delivery_ids.delete(delivery["id"])
      log "could not corroborate reconciled #{describe(delivery)}: #{error.message}; retried on the next webhook check"
    end

    # Not emitted, but never silent: the event, the project and the recording
    # go in the log, so a trigger too old to replay safely is a hole the
    # operator can see and hand over by hand.
    def report_unrecovered(registration, delivery)
      @settled_delivery_ids << delivery["id"]
      log "MISSED and NOT recovered: delivery #{delivery["id"]} of #{describe(delivery)} on project " \
        "#{registration.project} never reached this connector (#{describe_response(delivery)}) at " \
        "#{delivery["created_at"]}, older than the #{@lookback}s reconciliation window#{recording_note(delivery)}; " \
        "if it was a trigger, hand it to the agent by hand"
    end

    def describe(delivery)
      "event #{body(delivery)["id"]} (#{body(delivery)["kind"]})"
    end

    def describe_response(delivery)
      code = delivery.dig("response", "code")

      if code.is_a?(Integer) && code.positive?
        "answered HTTP #{code}"
      else
        "no response: the connection failed"
      end
    end

    def recording_note(delivery)
      app_url = body(delivery).dig("recording", "app_url")
      " — #{app_url}" if app_url
    end

    def body(delivery)
      delivery.dig("request", "body") || {}
    end

    def log(message)
      @logger.puts message
    end
end
