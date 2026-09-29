require "test_helper"

class PipelineTest < Minitest::Test
  def setup
    @operator = operator_identity
    @agent = agent_identity
    @output = StringIO.new
    @logs = StringIO.new
  end

  def test_emits_one_line_for_a_trusted_event
    runner = corroborating_runner
    pipeline(runner).process(sample_payload)

    assert_equal 1, @output.string.lines.length
    assert_equal 99001, JSON.parse(@output.string)["event_id"]
  end

  def test_dedupes_repeated_event_id
    runner = corroborating_runner
    pipeline = pipeline(runner)

    pipeline.process(sample_payload)
    pipeline.process(sample_payload)

    assert_equal 1, @output.string.lines.length
  end

  def test_ignores_event_from_a_non_operator
    runner = FakeCommandRunner.new

    pipeline(runner).process(sample_payload("creator" => { "email_address" => "someone@example.com" }))

    assert_empty @output.string
    assert_empty runner.commands
  end

  def test_ignores_non_actionable_kind
    pipeline(FakeCommandRunner.new).process(sample_payload("kind" => "comment_archived"))

    assert_empty @output.string
  end

  # The bug this covers: a message drafted first and published later never
  # produces a `message_created` delivery. bc3 records that event while the
  # recording is still drafted, refuses to relay it ("don't leak drafts") and
  # never re-relays it, so the mention arrives only as the publication itself.
  def test_emits_for_a_message_published_from_a_draft
    runner = FakeCommandRunner.new
    runner.stub "basecamp show", stdout: envelope(published_message)
    stub_history runner

    pipeline(runner).process(draft_published_payload)

    assert_equal 1, @output.string.lines.length
    assert_equal "message_active", JSON.parse(@output.string)["kind"]
    assert_equal({ "mentioned" => true, "subscribed" => false }, emitted_trigger)
  end

  # A draft is visible to nobody but its author and bc3 relays no event for
  # one, so a delivery naming a still-drafted recording is a forgery — and
  # emitting it would hand the agent an unpublished message.
  def test_does_not_emit_for_a_message_basecamp_still_marks_a_draft
    runner = FakeCommandRunner.new
    runner.stub "basecamp show", stdout: envelope(published_message("status" => "drafted"))
    stub_history runner

    refute pipeline(runner).process(draft_published_payload)

    assert_empty @output.string
    assert_match(/not corroborated/, @logs.string)
  end

  def test_dedupes_a_redelivered_publication
    runner = FakeCommandRunner.new
    runner.stub "basecamp show", stdout: envelope(published_message)
    stub_history runner
    pipeline = pipeline(runner)

    pipeline.process(draft_published_payload)
    pipeline.process(draft_published_payload)

    assert_equal 1, @output.string.lines.length
  end

  def test_ignores_a_comment_that_neither_mentions_nor_subscribes_the_agent
    recording = sample_recording("content" => "<p>just a normal comment, no mention</p>")
    runner = FakeCommandRunner.new
    runner.stub "basecamp show", stdout: envelope(recording)
    stub_history runner
    runner.stub "subscriptions show", stdout: subscribers_envelope(999)

    pipeline(runner).process(sample_payload("recording" => recording))

    assert_empty @output.string
    assert_match(/does not target the agent/, @logs.string)
  end

  def test_emits_for_a_comment_on_a_recording_the_agent_subscribes_to
    recording = sample_recording("content" => "<p>no mention, just an update</p>")
    runner = FakeCommandRunner.new
    runner.stub "basecamp show", stdout: envelope(recording)
    stub_history runner
    runner.stub "subscriptions show", stdout: subscribers_envelope(200)

    pipeline(runner).process(sample_payload("recording" => recording))

    assert_equal 1, @output.string.lines.length
    assert_equal "comment_created", JSON.parse(@output.string)["kind"]
  end

  def test_ignores_the_agents_own_comment_on_a_subscribed_recording
    author = { "id" => 200, "name" => "Clawdito", "email_address" => "clawdito@example.com" }
    recording = sample_recording("content" => "<p>my own reply</p>", "creator" => author)
    runner = FakeCommandRunner.new

    pipeline(runner).process(sample_payload("creator" => author, "recording" => recording))

    assert_empty @output.string
    assert_empty runner.commands
  end

  def test_ignores_a_third_partys_comment_on_a_subscribed_recording
    author = { "id" => 400, "email_address" => "sam@elsewhere.net" }
    recording = sample_recording("content" => "<p>hi</p>", "creator" => author)
    runner = FakeCommandRunner.new

    pipeline(runner).process(sample_payload("creator" => author, "recording" => recording))

    assert_empty @output.string
    assert_empty runner.commands
  end

  def test_a_forged_comment_kind_pointing_at_a_subscribed_message_cannot_emit
    # The POST claims comment_created but names an existing subscribed Message
    # the operator authored. Creator corroborates and the agent even subscribes,
    # but the authoritative recording is not a Comment, so nothing is emitted.
    message = sample_recording("type" => "Message", "content" => "<p>an old message, no mention</p>")
    runner = FakeCommandRunner.new
    runner.stub "basecamp show", stdout: envelope(message)
    stub_history runner
    runner.stub "subscriptions show", stdout: subscribers_envelope(200)

    pipeline(runner).process(sample_payload("recording" => message))

    assert_empty @output.string
    assert_match(/does not target the agent/, @logs.string)
    assert_empty runner.commands_matching(/subscriptions show/)
  end

  def test_a_forged_subscribed_flag_in_the_payload_cannot_emit
    # The POST claims agent_subscribed=true, but the agent is not really a
    # subscriber. The verifier discards the claimed flag and stamps its own from
    # the live subscribers API, so the event is dropped, not emitted.
    recording = sample_recording("content" => "<p>no mention</p>")
    runner = FakeCommandRunner.new
    runner.stub "basecamp show", stdout: envelope(recording)
    stub_history runner
    runner.stub "subscriptions show", stdout: subscribers_envelope(999)

    pipeline(runner).process(sample_payload("agent_subscribed" => true, "recording" => recording))

    assert_empty @output.string
    assert_match(/does not target the agent/, @logs.string)
  end

  def test_drops_uncorroborated_event
    runner = FakeCommandRunner.new
    runner.stub "basecamp show", stdout: envelope(sample_recording("creator" => { "id" => 999 }))
    stub_history runner

    pipeline = pipeline(runner)

    refute pipeline.process(sample_payload)
    assert_empty @output.string
    assert_match(/not corroborated/, @logs.string)
  end

  def test_an_uncorroborated_event_is_retried_when_delivered_again
    runner = FakeCommandRunner.new
    runner.stub "basecamp show", exit_status: 2, stdout: error_envelope("not_found", "Resource not found"), once: true
    runner.stub "basecamp show", stdout: envelope(sample_recording)
    stub_history runner
    pipeline = pipeline(runner)

    refute pipeline.process(sample_payload)
    assert pipeline.process(sample_payload)

    assert_equal 1, @output.string.lines.length
  end

  # One lost keyring probe must cost nothing visible: the client's retry
  # absorbs it, the event settles on this delivery, and the redelivery
  # Basecamp would send anyway is a duplicate.
  def test_an_event_corroborated_after_one_transient_failure_is_emitted_exactly_once
    runner = FakeCommandRunner.new
    runner.stub "basecamp show", exit_status: 3, once: true,
      stdout: error_envelope("auth_required", "Not authenticated for profile:clawdito: credentials not found")
    runner.stub "basecamp show", stdout: envelope(sample_recording)
    stub_history runner
    pipeline = pipeline(runner)

    assert pipeline.process(sample_payload)
    assert pipeline.process(sample_payload)

    assert_equal 1, @output.string.lines.length
    assert_equal 2, runner.commands_matching(/basecamp show/).length
    refute_match(/not corroborated/, @logs.string)
  end

  # A failure that outlasts the retries is no verdict: it propagates (for the
  # webhook handler to answer 503) rather than logging "not corroborated",
  # and forgets the id so the redelivery is verified afresh — and emitted
  # exactly once.
  def test_a_transient_failure_that_outlasts_the_retries_propagates_and_forgets_the_event
    runner = FakeCommandRunner.new
    stub_transient_failure runner, "basecamp show"
    runner.stub "basecamp show", stdout: envelope(sample_recording)
    stub_history runner
    pipeline = pipeline(runner)

    assert_raises(BasecampAgentConnector::Basecamp::Client::TransientError) { pipeline.process(sample_payload) }
    assert_empty @output.string
    refute_match(/not corroborated/, @logs.string)

    assert pipeline.process(sample_payload)
    assert pipeline.process(sample_payload)

    assert_equal 1, @output.string.lines.length
  end

  def test_a_settled_event_reports_a_verdict
    runner = FakeCommandRunner.new
    runner.stub "basecamp show", stdout: envelope(sample_recording)
    stub_history runner
    pipeline = pipeline(runner)

    assert pipeline.process(sample_payload)
    assert pipeline.process(sample_payload)
    assert pipeline.process(sample_payload("kind" => "comment_archived"))
    assert_equal 1, @output.string.lines.length
  end

  # The interleaving the pipeline's lock prevents: a verification overruns
  # bc3's delivery timeout, the redelivery arrives while it is in flight, and
  # the original then fails. Answered 200 as a duplicate, the redelivery
  # would have been the last one; waiting, it becomes the fresh attempt.
  def test_a_redelivery_during_an_in_flight_verification_waits_for_its_outcome
    gate = Queue.new
    runner = FakeCommandRunner.new
    stub_transient_failure runner, "basecamp show"
    runner.stub "basecamp show", stdout: envelope(sample_recording)
    stub_history runner
    gated = Object.new
    gated.define_singleton_method(:run) { |*command, **options| gate.pop; runner.run(*command, **options) }
    pipeline = pipeline(gated)
    original = Thread.new { pipeline.process(sample_payload) rescue $! }
    Thread.pass while original.alive? && original.status != "sleep"
    flunk "the original verification finished (#{original.value.inspect}) before blocking on the gate" unless original.alive?

    redelivery = Thread.new { pipeline.process(sample_payload) }
    5.times { gate << :go }

    assert_kind_of BasecampAgentConnector::Basecamp::Client::TransientError, original.value
    assert redelivery.value
    assert_equal 1, @output.string.lines.length
  end

  # Waiting is per event id: a delivery of a different id is verified while
  # the first is still parked on its CLI call, not queued behind it — a
  # burst serialized behind one slow verification would overrun bc3's 10s
  # delivery timeout for every delivery after it.
  def test_distinct_events_are_verified_concurrently
    gate = Queue.new
    other_recording = sample_recording("id" => 457, "url" => "https://3.basecamp.com/000/buckets/222/comments/457.json",
      "app_url" => "https://3.basecamp.com/000/buckets/222/comments/457")
    runner = FakeCommandRunner.new
    stub_history runner, sample_payload, sample_payload("id" => 99003, "recording" => other_recording)
    runner.stub "comments/456", stdout: envelope(sample_recording)
    runner.stub "comments/457", stdout: envelope(other_recording)
    gated = Object.new
    gated.define_singleton_method(:run) do |*command, **options|
      gate.pop if command.join(" ").match?(%r{show \S*comments/456})
      runner.run(*command, **options)
    end
    pipeline = pipeline(gated)
    first = Thread.new { pipeline.process(sample_payload) }
    Thread.pass while first.alive? && first.status != "sleep"
    flunk "the first verification finished before blocking on the gate" unless first.alive?

    second = Thread.new { pipeline.process(sample_payload("id" => 99003, "recording" => other_recording)) }
    refute_nil second.join(2), "the second event queued behind the first's in-flight verification"
    assert second.value
    assert first.alive?, "the first verification settled without passing its gate"

    gate << :go
    assert first.value
    assert_equal [ 99003, 99001 ], @output.string.lines.map { |line| JSON.parse(line)["event_id"] }
  ensure
    gate << :go
  end

  def test_emits_for_a_boost_on_the_agents_work_by_the_operator
    runner = FakeCommandRunner.new
    runner.stub "api get /my/boosts.json", stdout: envelope([ received_boost ])

    pipeline(runner).process(boost_payload)

    emitted = JSON.parse(@output.string)
    assert_equal 88001, emitted["event_id"]
    assert_equal "boost_created", emitted["kind"]
    assert_equal "🔥", emitted["details"]["boost"]["content"]
  end

  def test_the_emitted_boost_is_the_fetched_one_not_the_claimed_one
    runner = FakeCommandRunner.new
    runner.stub "api get /my/boosts.json", stdout: envelope([ received_boost ])

    pipeline(runner).process(boost_payload(received_boost("content" => "forged claim")))

    assert_equal "🔥", JSON.parse(@output.string)["details"]["boost"]["content"]
  end

  def test_a_forged_boosted_flag_in_the_payload_cannot_emit
    runner = FakeCommandRunner.new
    runner.stub "basecamp show", stdout: envelope(sample_recording("content" => "<p>no mention</p>"))
    stub_history runner
    runner.stub "subscriptions show", stdout: subscribers_envelope(999)

    payload = sample_payload("recording" => sample_recording("content" => "<p>no mention</p>"), "agent_boosted" => true)
    pipeline(runner).process(payload)

    assert_empty @output.string
    assert_match(/does not target the agent/, @logs.string)
  end

  def test_drops_a_boost_basecamp_no_longer_reports
    runner = FakeCommandRunner.new
    runner.stub "api get /my/boosts.json", stdout: envelope([])
    pipeline = pipeline(runner)

    refute pipeline.process(boost_payload)
    assert_empty @output.string
    assert_match(/not corroborated/, @logs.string)
  end

  def test_ignores_a_boost_from_an_unauthorized_booster_without_fetching
    runner = FakeCommandRunner.new

    pipeline(runner).process(boost_payload(received_boost("booster" => { "id" => 400, "email_address" => "sam@elsewhere.net" })))

    assert_empty @output.string
    assert_empty runner.commands
  end

  def test_ignores_the_agents_own_boost_without_fetching
    runner = FakeCommandRunner.new

    pipeline(runner).process(boost_payload(received_boost("booster" => { "id" => 200, "email_address" => "clawdito@example.com" })))

    assert_empty @output.string
    assert_empty runner.commands
  end

  # Email-keyed trust modes reach boosts only when the agent can see the
  # booster's address (bc3 redacts emails from non-admin viewers), so this
  # models an agent allowed to see it.
  def test_an_authorized_colleagues_boost_emits_under_domain_trust
    runner = FakeCommandRunner.new
    booster = { "id" => 300, "name" => "Marie", "email_address" => "marie@example.com" }
    runner.stub "api get /my/boosts.json", stdout: envelope([ received_boost("booster" => booster) ])

    pipeline(runner, authorizer: authorizer(trust: :domain, domains: [ "example.com" ])).process \
      boost_payload(received_boost("booster" => booster))

    assert_equal "marie@example.com", JSON.parse(@output.string)["creator"]["email_address"]
  end

  def test_a_redacted_colleagues_boost_cannot_authorize_email_keyed_trust
    redacted = { "id" => 300, "name" => "Marie", "email_address" => "m••••@•••••••.•••" }
    runner = FakeCommandRunner.new
    runner.stub "api get /my/boosts.json", stdout: envelope([ received_boost("booster" => redacted) ])

    pipeline(runner, authorizer: authorizer(trust: :allowlist, emails: [ "marie@example.com" ])).process \
      boost_payload(received_boost("booster" => redacted))

    assert_empty @output.string
  end

  def test_emits_for_an_assignment_of_the_agent_by_the_operator
    runner = FakeCommandRunner.new
    runner.stub "basecamp show", stdout: envelope(assigned_recording)
    stub_history runner

    pipeline(runner).process(assignment_payload)

    assert_equal 1, @output.string.lines.length
    assert_equal "kanban_card_assignment_changed", JSON.parse(@output.string)["kind"]
  end

  def test_ignores_an_assignment_made_by_a_non_operator
    runner = FakeCommandRunner.new

    pipeline(runner).process(assignment_payload("creator" => { "email_address" => "someone@example.com" }))

    assert_empty @output.string
    assert_empty runner.commands
  end

  def test_ignores_an_assignment_that_does_not_add_the_agent
    pipeline(FakeCommandRunner.new).process(assignment_payload("details" => { "added_person_ids" => [ 999 ] }))

    assert_empty @output.string
  end

  def test_drops_event_whose_claimed_author_is_not_the_authoritative_one
    # The POST claims the operator's email on the real author's Person id; the
    # corroborated creator (Sam) is who must be authorized, and isn't.
    runner = FakeCommandRunner.new
    runner.stub "basecamp show", stdout: envelope(sample_recording("creator" => { "id" => 400, "name" => "Sam", "email_address" => "sam@elsewhere.net" }))
    stub_history runner

    pipeline(runner).process(sample_payload("creator" => { "id" => 400, "name" => "Sam", "email_address" => "operator@example.com" }))

    assert_empty @output.string
    assert_match(/authoritative author is not authorized/, @logs.string)
  end

  def test_drops_a_forged_mention_when_the_authoritative_recording_has_none
    # The POST claims a mention of the agent (passing the pre-filter) but points
    # at a real operator recording that never mentioned the agent. The verified
    # recording is authoritative and carries no mention, so it must not emit.
    runner = FakeCommandRunner.new
    runner.stub "basecamp show", stdout: envelope(sample_recording("content" => "<p>a plain operator note, no mention</p>"))
    stub_history runner
    runner.stub "subscriptions show", stdout: subscribers_envelope(999)

    pipeline(runner).process(sample_payload)

    assert_empty @output.string
    assert_match(/does not target the agent/, @logs.string)
  end

  def test_allowlist_emits_for_an_allowed_author
    runner = FakeCommandRunner.new
    runner.stub "basecamp show", stdout: envelope(sample_recording("creator" => colleague))
    stub_history runner

    pipeline(runner, authorizer: authorizer(trust: :allowlist, emails: [ "marie@example.com" ]))
      .process(sample_payload("creator" => colleague))

    assert_equal 1, @output.string.lines.length
    assert_equal "marie@example.com", JSON.parse(@output.string)["creator"]["email_address"]
  end

  def test_allowlist_ignores_an_author_not_on_the_list
    runner = FakeCommandRunner.new

    pipeline(runner, authorizer: authorizer(trust: :allowlist, emails: [ "marie@example.com" ]))
      .process(sample_payload("creator" => { "id" => 400, "email_address" => "sam@elsewhere.net" }))

    assert_empty @output.string
    assert_empty runner.commands
  end

  def test_project_trust_emits_for_any_corroborated_author
    runner = FakeCommandRunner.new
    runner.stub "basecamp show", stdout: envelope(sample_recording("creator" => colleague))
    stub_history runner

    pipeline(runner, authorizer: authorizer(trust: :project)).process(sample_payload("creator" => colleague))

    assert_equal 1, @output.string.lines.length
  end

  def test_project_trust_drops_an_author_basecamp_marks_as_a_client
    runner = FakeCommandRunner.new
    runner.stub "basecamp show", stdout: envelope(sample_recording("creator" => colleague.merge("client" => true)))
    stub_history runner

    pipeline(runner, authorizer: authorizer(trust: :project)).process(sample_payload("creator" => colleague))

    assert_empty @output.string
    assert_match(/authoritative author is not authorized/, @logs.string)
  end

  def test_project_trust_ignores_an_event_authored_by_the_agent_itself
    runner = FakeCommandRunner.new

    # client=>false so the drop is the Person-id self-exclusion guard, not the
    # fail-closed client check masking a regression in it.
    pipeline(runner, authorizer: authorizer(trust: :project))
      .process(sample_payload("creator" => { "id" => 200, "name" => "Clawdito", "email_address" => "clawdito@example.com", "client" => false }))

    assert_empty @output.string
    assert_empty runner.commands
  end

  def test_domain_trust_emits_for_a_matching_domain
    runner = FakeCommandRunner.new
    runner.stub "basecamp show", stdout: envelope(sample_recording("creator" => colleague))
    stub_history runner

    pipeline(runner, authorizer: authorizer(trust: :domain, domains: [ "example.com" ]))
      .process(sample_payload("creator" => colleague))

    assert_equal 1, @output.string.lines.length
  end

  def test_domain_trust_ignores_other_domains
    runner = FakeCommandRunner.new

    pipeline(runner, authorizer: authorizer(trust: :domain, domains: [ "example.com" ]))
      .process(sample_payload("creator" => { "id" => 400, "email_address" => "sam@elsewhere.net" }))

    assert_empty @output.string
    assert_empty runner.commands
  end

  def test_domain_trust_ignores_the_agent_itself_on_a_shared_domain
    runner = FakeCommandRunner.new

    pipeline(runner, authorizer: authorizer(trust: :domain, domains: [ "example.com" ]))
      .process(sample_payload("creator" => { "id" => 200, "name" => "Clawdito", "email_address" => "clawdito@example.com" }))

    assert_empty @output.string
    assert_empty runner.commands
  end

  def test_allowlist_emits_for_an_allowed_authors_comment_on_a_subscribed_recording
    # The subscription trigger passes the same trust gate as a mention: a
    # broadened mode's authors can drive the agent through a followed thread.
    recording = sample_recording("content" => "<p>no mention, just an update</p>", "creator" => colleague)
    runner = FakeCommandRunner.new
    runner.stub "basecamp show", stdout: envelope(recording)
    stub_history runner
    runner.stub "subscriptions show", stdout: subscribers_envelope(200)

    pipeline(runner, authorizer: authorizer(trust: :allowlist, emails: [ "marie@example.com" ]))
      .process(sample_payload("creator" => colleague, "recording" => recording))

    assert_equal 1, @output.string.lines.length
    assert_equal "marie@example.com", JSON.parse(@output.string)["creator"]["email_address"]
  end

  def test_project_trust_drops_a_client_authors_comment_on_a_subscribed_recording
    # Subscription targeting never bypasses the authorizer: even when the agent
    # really subscribes, the corroborated author must still be authorized. The
    # claimed payload denies client status (passing the pre-filter); Basecamp's
    # authoritative copy marks the author a client, and that copy decides.
    recording = sample_recording("content" => "<p>no mention</p>", "creator" => colleague.merge("client" => true))
    runner = FakeCommandRunner.new
    runner.stub "basecamp show", stdout: envelope(recording)
    stub_history runner
    runner.stub "subscriptions show", stdout: subscribers_envelope(200)

    pipeline(runner, authorizer: authorizer(trust: :project))
      .process(sample_payload("creator" => colleague, "recording" => recording))

    assert_empty @output.string
    assert_match(/authoritative author is not authorized/, @logs.string)
  end

  def test_broadened_trust_keeps_assignments_operator_only
    runner = FakeCommandRunner.new

    pipeline(runner, authorizer: authorizer(trust: :allowlist, emails: [ "marie@example.com" ]))
      .process(assignment_payload("creator" => colleague))

    assert_empty @output.string
    assert_empty runner.commands
  end

  # A verification that fails in a way nobody anticipated has reached no
  # verdict, so the id must not stay settled: otherwise one malformed POST
  # naming a real event's id would have its real delivery dropped as a
  # duplicate.
  def test_an_unexpected_failure_verifying_an_event_does_not_settle_its_id
    runner = corroborating_runner
    failing = Object.new
    calls = 0
    failing.define_singleton_method(:run) do |*command, **options|
      calls += 1
      raise TypeError, "no implicit conversion of Array into String" if calls == 1

      runner.run(*command, **options)
    end
    pipeline = pipeline(failing)

    assert_raises(TypeError) { pipeline.process(sample_payload) }
    pipeline.process(sample_payload)

    assert_equal 1, @output.string.lines.length
  end

  def test_a_payload_whose_id_or_locator_is_not_one_basecamp_sends_is_not_claimed
    runner = FakeCommandRunner.new

    [ sample_payload("id" => "99001"), sample_payload("id" => -1),
      sample_payload("recording" => sample_recording("url" => [], "app_url" => nil)) ].each do |payload|
      pipeline(runner, webhook: true).process(payload)
    end

    assert_empty runner.commands
  end

  # Only the id and the project to look in come from the POST: what is acted on
  # is Basecamp's delivery of that id.
  def test_the_webhook_route_acts_on_the_event_as_basecamp_delivered_it
    delivered = sample_payload("details" => { "from" => "basecamp" })
    asked = []
    pipeline(corroborating_runner, webhook: true,
      recorded_delivery: ->(event_id, project_id) { asked << [ event_id, project_id ] && delivered })
      .process(sample_payload("details" => { "from" => "the post" }))

    assert_equal [ [ 99001, 222 ] ], asked
    assert_equal 1, @output.string.lines.length
  end

  def test_a_delivery_history_that_could_not_be_read_propagates_with_nothing_settled
    unreadable = ->(_event_id, _project_id) { raise BasecampAgentConnector::Basecamp::Client::TransientError, "no answer" }
    pipeline = pipeline(corroborating_runner, webhook: true, recorded_delivery: unreadable)

    assert_raises(BasecampAgentConnector::Basecamp::Client::TransientError) { pipeline.process(sample_payload) }
    refute pipeline.heard?(99001)
  end

  def test_a_webhook_event_naming_no_project_has_no_delivery_to_look_for
    asked = false
    pipeline = pipeline(corroborating_runner, webhook: true, recorded_delivery: ->(*) { asked = true })

    refute pipeline.process(sample_payload("recording" => sample_recording("bucket" => nil)))
    refute asked
  end

  # The delivery reconciler replays bodies out of the webhook's own delivery
  # history, which is exactly what the route looks up.
  def test_a_replay_out_of_the_delivery_history_is_not_looked_up_again
    pipeline = pipeline(corroborating_runner, webhook: true, recorded_delivery: ->(*) { flunk "looked up again" })

    pipeline.process(sample_payload, attested: true)

    assert_equal 1, @output.string.lines.length
  end

  def test_a_delivered_event_on_a_recording_outside_the_watched_projects_is_dropped
    pipeline(corroborating_runner, webhook: true, recorded_delivery: ->(*) { sample_payload }, watched_projects: -> { [ 333 ] })
      .process(sample_payload)

    assert_empty @output.string
    assert_match(/dropped event 99001: its recording is in project 222, which this connector does not watch/, @logs.string)
  end

  def test_a_webhook_pipeline_must_be_able_to_read_what_basecamp_delivered_and_know_what_it_watches
    assert_raises(ArgumentError) { pipeline(FakeCommandRunner.new, webhook: true, recorded_delivery: nil) }
    assert_raises(ArgumentError) { pipeline(FakeCommandRunner.new, webhook: true, watched_projects: nil) }
  end

  # bc3 delivers an agent acting on someone's behalf as that person, with the
  # agent as `performed_by`. The agent did it, not the person, so it is the
  # agent that must be authorized.
  def test_an_event_an_agent_performed_on_the_operators_behalf_is_not_the_operators
    helper = { "id" => 900, "name" => "Helper", "personable_type" => "Agent" }
    runner = FakeCommandRunner.new
    runner.stub "basecamp show", stdout: envelope(assigned_recording)
    stub_history runner
    delegated = assignment_payload("performed_by" => helper)

    pipeline(runner, webhook: true, recorded_delivery: ->(*) { delegated }).process(assignment_payload)
    pipeline(corroborating_runner, webhook: true, recorded_delivery: ->(*) { sample_payload("performed_by" => helper) })
      .process(sample_payload)

    assert_empty @output.string
    assert_equal 2, @logs.string.scan(/authoritative author is not authorized/).length
  end

  # The event vouches for the recording as its actor left it, but the agent is
  # handed the recording as it is now. A real operator mention, replayed from
  # the delivery history after a member edited their own instructions into
  # the recording, must not carry the member's words under the operator's name.
  def test_a_real_event_cannot_carry_someone_elses_later_edit
    member = { "id" => 555, "name" => "Mallory" }
    runner = FakeCommandRunner.new
    runner.stub "basecamp show", stdout: envelope(sample_recording)
    stub_history runner, recorded_event(sample_payload, "id" => 99010, "action" => "content_changed", "creator" => member), sample_payload

    pipeline(runner, webhook: true).process(sample_payload, attested: true)

    assert_empty @output.string
    assert_match(/dropped event 99001: not corroborated/, @logs.string)
  end

  # bc3 creates each repetition of a repeating to-do as the to-do's creator,
  # copying the text and assignees as they stand when the last one was
  # completed, whoever wrote them. So a genuine delivery of its creation says
  # nothing about who wrote what the agent would be handed.
  def test_a_trigger_on_a_repeating_to_do_is_dropped
    todo = sample_recording("type" => "Todo", "repetition_schedule" => { "frequency" => "every_week" })
    creation = sample_payload("kind" => "todo_created", "recording" => todo)
    runner = FakeCommandRunner.new
    runner.stub "basecamp show", stdout: envelope(todo)
    stub_history runner, creation

    assert pipeline(runner, webhook: true, recorded_delivery: ->(*) { creation }).process(creation)

    assert_empty @output.string
    assert_match(/dropped event 99001: its recording is a repeating to-do/, @logs.string)
  end

  # Its steps, and whom they are assigned to, are copied into each repetition
  # the same way, and a step shows no schedule of its own; the to-do's can be
  # removed afterwards. So a step is acted on only when it is a card's.
  def test_a_trigger_on_a_step_of_a_to_do_is_dropped
    step = assigned_recording("id" => 460, "type" => "Kanban::Step",
      "parent" => { "id" => 459, "type" => "Todo", "app_url" => "https://3.basecamp.com/000/buckets/222/todos/459" })
    assignment = assignment_payload("kind" => "kanban_step_assignment_changed", "recording" => step)
    runner = FakeCommandRunner.new
    runner.stub "basecamp show", stdout: envelope(step)
    stub_history runner, assignment

    assert pipeline(runner, webhook: true, recorded_delivery: ->(*) { assignment }).process(assignment)

    assert_empty @output.string
    assert_match(/dropped event 99002: its recording is a step on a to-do/, @logs.string)
  end

  def test_a_trigger_on_a_cards_step_is_acted_on
    step = assigned_recording("id" => 460, "type" => "Kanban::Step",
      "parent" => { "id" => 789, "type" => "Kanban::Card", "app_url" => "https://3.basecamp.com/000/buckets/222/card_tables/cards/789" })
    assignment = assignment_payload("kind" => "kanban_step_assignment_changed", "recording" => step)
    runner = FakeCommandRunner.new
    runner.stub "basecamp show", stdout: envelope(step)
    stub_history runner, assignment

    pipeline(runner, webhook: true, recorded_delivery: ->(*) { assignment }).process(assignment)

    assert_equal 1, @output.string.lines.length
  end

  def test_assignment_opt_in_lets_an_authorized_author_assign
    runner = FakeCommandRunner.new
    runner.stub "basecamp show", stdout: envelope(assigned_recording)
    stub_history runner

    pipeline(runner, authorizer: authorizer(trust: :allowlist, emails: [ "marie@example.com" ], allow_assignments: true))
      .process(assignment_payload("creator" => colleague))

    assert_equal 1, @output.string.lines.length
  end

  # The emitted line carries the verifier's own verdict on why the event
  # targets the agent, so the watcher never decodes mention markup itself.
  def test_a_mention_emits_a_mentioned_trigger
    pipeline(corroborating_runner).process(sample_payload)

    assert_equal({ "mentioned" => true, "subscribed" => false }, emitted_trigger)
  end

  def test_a_comment_on_a_subscribed_recording_emits_a_subscribed_trigger
    recording = sample_recording("content" => "<p>no mention, just an update</p>")
    runner = FakeCommandRunner.new
    runner.stub "basecamp show", stdout: envelope(recording)
    stub_history runner
    runner.stub "subscriptions show", stdout: subscribers_envelope(200)

    pipeline(runner).process(sample_payload("recording" => recording))

    assert_equal({ "mentioned" => false, "subscribed" => true }, emitted_trigger)
  end

  def test_an_assignment_emits_neither_trigger_verdict
    runner = FakeCommandRunner.new
    runner.stub "basecamp show", stdout: envelope(assigned_recording)
    stub_history runner

    pipeline(runner).process(assignment_payload)

    assert_equal({ "mentioned" => false, "subscribed" => false }, emitted_trigger)
  end

  def test_mentioned_is_a_fact_about_the_content_whatever_the_kind
    runner = FakeCommandRunner.new
    runner.stub "basecamp show", stdout: envelope(assigned_recording("content" => "<p>#{mention_html(person_id: 200)} owns this</p>"))
    stub_history runner

    pipeline(runner).process(assignment_payload)

    assert_equal({ "mentioned" => true, "subscribed" => false }, emitted_trigger)
  end

  def test_a_chat_line_mention_emits_a_mentioned_trigger
    runner = FakeCommandRunner.new
    runner.stub "chat line ", stdout: envelope(chat_line)

    pipeline(runner).process(chat_line_payload)

    assert_equal({ "mentioned" => true, "subscribed" => false }, emitted_trigger)
  end

  def test_a_boost_emits_neither_trigger_verdict
    runner = FakeCommandRunner.new
    runner.stub "api get /my/boosts.json", stdout: envelope([ received_boost ])

    pipeline(runner).process(boost_payload)

    assert_equal({ "mentioned" => false, "subscribed" => false }, emitted_trigger)
  end

  def test_the_emitted_trigger_is_the_verifiers_verdict_not_a_claim_in_the_payload
    # The POST claims agent_mentioned=true on a comment whose authoritative
    # content mentions nobody; it emits only by subscription, and says so.
    recording = sample_recording("content" => "<p>no mention</p>")
    runner = FakeCommandRunner.new
    runner.stub "basecamp show", stdout: envelope(recording)
    stub_history runner
    runner.stub "subscriptions show", stdout: subscribers_envelope(200)

    pipeline(runner).process(sample_payload("agent_mentioned" => true, "recording" => recording))

    assert_equal({ "mentioned" => false, "subscribed" => true }, emitted_trigger)
  end

  # Basecamp never delivers either kind by webhook, so on the webhook pipeline
  # either is an impostor, refused before anything is verified — whichever
  # path brought it there, a live delivery or one replayed from the history.
  def test_the_webhook_pipeline_refuses_the_kinds_basecamp_never_delivers_by_webhook
    runner = FakeCommandRunner.new
    pipeline = pipeline(runner, webhook: true)

    assert pipeline.process(boost_payload)
    assert pipeline.process(chat_line_payload)

    assert_empty @output.string
    assert_empty runner.commands
    assert_match(/ignored boost-kind payload/, @logs.string)
    assert_match(/ignored chat-kind payload/, @logs.string)
  end

  def test_has_heard_an_event_it_emitted_but_not_one_basecamp_would_not_corroborate
    runner = FakeCommandRunner.new
    runner.stub "basecamp show", stdout: envelope(sample_recording), once: true
    runner.stub "basecamp show", stdout: envelope(sample_recording("status" => "drafted"))
    stub_history runner
    pipeline = pipeline(runner)

    pipeline.process(sample_payload)
    pipeline.process(sample_payload("id" => 99002))

    assert pipeline.heard?(99001)
    refute pipeline.heard?(99002)
  end

  private
    def emitted_trigger
      JSON.parse(@output.string)["trigger"]
    end

    def colleague
      { "id" => 300, "name" => "Marie", "email_address" => "marie@example.com", "client" => false }
    end

    def corroborating_runner
      runner = FakeCommandRunner.new
      runner.stub "basecamp show", stdout: envelope(sample_recording)
      stub_history runner
      runner
    end

    # A webhook pipeline finds no delivery of anything unless a test says what
    # Basecamp delivered. The fixtures' recordings are all in project 222.
    def pipeline(runner, authorizer: authorizer(), webhook: false, recorded_delivery: ->(_event_id, _project_id) { },
      watched_projects: -> { [ 222 ] })
      BasecampAgentConnector::Basecamp::Pipeline.new \
        authorizer: authorizer,
        agent: @agent,
        verifier: BasecampAgentConnector::Basecamp::Verifier.new(basecamp_cli: build_cli(runner), agent: @agent),
        emitter: BasecampAgentConnector::Emitter.new(output: @output),
        webhook: webhook,
        recorded_delivery: recorded_delivery,
        watched_projects: watched_projects,
        logger: @logs
    end
end
