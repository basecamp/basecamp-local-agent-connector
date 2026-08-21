require "test_helper"

class PollerTest < Minitest::Test
  APP_URL = "https://app.basecamp.com/000/buckets/222/card_tables/cards/789#__recording_456".freeze

  def test_a_mention_becomes_a_payload_built_from_the_fetched_recording
    runner = FakeCommandRunner.new
    stub_listings runner, notifications: [ notification ]
    runner.stub "show https://3.basecampapi.com/000/buckets/222/comments/456.json", stdout: envelope(sample_recording)

    payload = only(poller(runner).payloads)

    assert_equal 4940356197, payload["id"]
    assert_equal "comment_created", payload["kind"]
    assert_equal sample_recording, payload["recording"]
  end

  # The listing redacts every email but the reader's own, so a payload built from
  # it would fail the operator check that a payload built from the fetch passes.
  def test_the_creator_comes_from_the_recording_rather_than_the_redacted_listing
    runner = FakeCommandRunner.new
    stub_listings runner, notifications: [ notification("creator" => { "id" => 100, "email_address" => "o••••••@••••••.•••" }) ]
    runner.stub "show ", stdout: envelope(sample_recording)

    assert_equal "operator@example.com", only(poller(runner).payloads).dig("creator", "email_address")
  end

  def test_a_notification_already_handled_is_not_emitted_again
    runner = FakeCommandRunner.new
    stub_listings runner, notifications: [ notification ]
    runner.stub "show ", stdout: envelope(sample_recording)
    state = FakePollState.new

    assert_equal 1, poller(runner, state: state).payloads.length
    assert_empty poller(runner, state: state).payloads
  end

  # A blip on a bad connection must not swallow one of the operator's mentions:
  # an unfetchable notification stays unremembered so the next round retries it.
  def test_a_failed_fetch_is_retried_rather_than_dropped
    runner = FakeCommandRunner.new
    stub_listings runner, notifications: [ notification ]
    runner.stub "show ", stderr: "connection reset", exit_status: 1
    state = FakePollState.new

    assert_empty poller(runner, state: state).payloads
    refute state.seen?(BasecampAgentConnector::Basecamp::Poller::NOTIFICATIONS, 4940356197)
  end

  def test_a_notification_from_an_unwatched_project_is_skipped_and_not_re_examined
    runner = FakeCommandRunner.new
    stub_listings runner, notifications: [ notification("bucket_name" => "Somebody Else's Project") ]
    state = FakePollState.new

    assert_empty poller(runner, state: state, projects: [ "BC5 Calendar" ]).payloads
    assert state.seen?(BasecampAgentConnector::Basecamp::Poller::NOTIFICATIONS, 4940356197)
    assert_empty runner.commands_matching(/show/)
  end

  def test_a_card_in_a_watched_column_becomes_a_creation_payload_without_a_fetch
    runner = FakeCommandRunner.new
    stub_listings runner
    runner.stub "cards list --project 222 --column 555", stdout: envelope([ created_card_recording ])

    payload = only(poller(runner, watched_columns: [ watched_column ]).payloads)

    assert_equal "kanban_card_created", payload["kind"]
    assert_equal 901, payload["id"]
    assert_empty runner.commands_matching(/show/)
  end

  # A card listing says who is assigned but never who assigned them, and the
  # operator check needs the assigner.
  def test_an_assignment_takes_its_creator_from_the_cards_history
    runner = FakeCommandRunner.new
    stub_listings runner, assignments: [ assigned_recording ]
    runner.stub "events ", stdout: envelope([ assignment_event ])

    payload = only(poller(runner).payloads)

    assert_equal "kanban_card_assignment_changed", payload["kind"]
    assert_equal "operator@example.com", payload.dig("creator", "email_address")
    assert_equal [ 200 ], payload.dig("details", "added_person_ids")
  end

  def test_a_card_assigned_to_somebody_else_produces_nothing
    runner = FakeCommandRunner.new
    stub_listings runner, assignments: [ assigned_recording ]
    runner.stub "events ", stdout: envelope([ assignment_event("details" => { "added_person_ids" => [ 777 ] }) ])

    assert_empty poller(runner).payloads
  end

  def test_seeding_remembers_what_is_waiting_without_emitting_any_of_it
    runner = FakeCommandRunner.new
    stub_listings runner, notifications: [ notification ]
    runner.stub "cards list --project 222 --column 555", stdout: envelope([ created_card_recording ])
    state = FakePollState.new
    seeded = poller(runner, state: state, watched_columns: [ watched_column ])

    seeded.seed

    assert state.seen?(BasecampAgentConnector::Basecamp::Poller::NOTIFICATIONS, 4940356197)
    assert state.seen?(BasecampAgentConnector::Basecamp::Poller::CARDS, 901)
    assert_empty runner.commands_matching(/show/)
  end

  # Every read the poller makes runs as the agent, not as whoever the CLI
  # defaults to. Reading as the operator would let the bot act on recordings the
  # bot itself cannot see, and it couples the bridge to a second set of
  # credentials that can fail independently — both happened before this was
  # threaded through.
  def test_every_listing_and_fetch_runs_as_the_agent
    runner = FakeCommandRunner.new
    stub_listings runner, notifications: [ notification ], assignments: [ assigned_recording ]
    runner.stub "cards list --project 222 --column 555", stdout: envelope([ created_card_recording ])
    runner.stub "show ", stdout: envelope(sample_recording)
    runner.stub "events ", stdout: envelope([ assignment_event ])

    poller(runner, watched_columns: [ watched_column ]).payloads

    commands = runner.commands_matching(/./)
    assert_equal 5, commands.length
    unprofiled = commands.reject { |command| command.each_cons(2).include?([ "--profile", "clawdito" ]) }
    assert_empty unprofiled, "every read must name the agent profile: #{unprofiled.inspect}"
  end

  # The bug this guards: a card filed into a watched column ALSO notifies the
  # bot, so the same card arrived twice in one round under two different event
  # ids — the card's from the column, the notification's from the feed. Nothing
  # downstream deduplicates, so each copy started its own agent on the same work.
  def test_one_card_seen_by_two_sources_is_emitted_once
    runner = FakeCommandRunner.new
    card = created_card_recording
    stub_listings runner, notifications: [ notification("app_url" => "https://app.basecamp.com/000/buckets/222/card_tables/cards/901") ]
    runner.stub "cards list --project 222 --column 555", stdout: envelope([ card ])
    runner.stub "show ", stdout: envelope(card)

    payloads = poller(runner, watched_columns: [ watched_column ]).payloads

    assert_equal 1, payloads.length
  end

  # And the column copy is the one that survives, because it is the copy that
  # does not need the operator to have authored anything. A bot-filed card has
  # no operator anywhere on it, so letting the notification copy win would hand
  # the trust filter a payload it is obliged to drop.
  def test_the_surviving_copy_is_the_one_from_the_watched_column
    runner = FakeCommandRunner.new
    card = created_card_recording
    stub_listings runner, notifications: [ notification("app_url" => "https://app.basecamp.com/000/buckets/222/card_tables/cards/901") ]
    runner.stub "cards list --project 222 --column 555", stdout: envelope([ card ])
    runner.stub "show ", stdout: envelope(card)

    payload = only(poller(runner, watched_columns: [ watched_column ]).payloads)

    assert_equal 901, payload["id"]
  end

  # Across rounds too, not just within one: the second round sees the card in the
  # column listing again and the notification in the feed again.
  def test_a_card_already_emitted_by_one_source_is_not_re_emitted_by_another
    runner = FakeCommandRunner.new
    card = created_card_recording
    runner.stub "cards list --project 222 --column 555", stdout: envelope([ card ])
    runner.stub "show ", stdout: envelope(card)
    state = FakePollState.new

    stub_listings runner
    assert_equal 1, poller(runner, state: state, watched_columns: [ watched_column ]).payloads.length

    stub_listings runner, notifications: [ notification("app_url" => "https://app.basecamp.com/000/buckets/222/card_tables/cards/901") ]
    assert_empty poller(runner, state: state, watched_columns: [ watched_column ]).payloads
  end

  # A record with no id stringifies to the same empty key as every other record
  # with no id, so remembering one marked all of them handled forever.
  def test_a_record_with_no_id_does_not_mark_every_other_idless_record_handled
    runner = FakeCommandRunner.new
    stub_listings runner, notifications: [ notification("id" => nil, "bucket_name" => "Somebody Else's Project") ]
    state = FakePollState.new

    assert_empty poller(runner, state: state, projects: [ "BC5 Calendar" ]).payloads
    refute state.seen?(BasecampAgentConnector::Basecamp::Poller::NOTIFICATIONS, nil)
  end

  def test_a_listing_that_cannot_be_read_does_not_take_the_round_down
    runner = FakeCommandRunner.new
    runner.stub "notifications list", stderr: "offline", exit_status: 1
    runner.stub "cards list --all-projects --assignee Clawdito", stdout: envelope([])

    assert_empty poller(runner).payloads
  end

  def test_a_card_whose_verification_could_not_be_made_is_offered_again
    runner = FakeCommandRunner.new
    stub_listings runner
    runner.stub "cards list --project 222 --column 555", stdout: envelope([ created_card_recording ])
    state = FakePollState.new
    polling = poller(runner, state: state, watched_columns: [ watched_column ])

    payload = only(polling.payloads)
    polling.rollback payload

    refute_empty polling.payloads, "a card the Verifier could not reach must come back next round"
  end

  def test_a_card_that_was_verified_is_not_offered_again
    runner = FakeCommandRunner.new
    stub_listings runner
    runner.stub "cards list --project 222 --column 555", stdout: envelope([ created_card_recording ])
    state = FakePollState.new
    polling = poller(runner, state: state, watched_columns: [ watched_column ])

    only polling.payloads

    assert_empty polling.payloads, "rollback must not fire for a card that was handled"
  end

  private
    # The failure this pair exists for: a transient read failure used to leave the
    # event marked handled, so the next round filtered it out and it was gone. The
    # message is the one the bridge actually logged on 2026-08-21, ten times in a
    # 92-line run, while the profile's token had a fortnight left on it.
    BLIP = "Not authenticated for profile:on-call-bot: credentials not found for profile:on-call-bot".freeze

    def only(payloads)
      assert_equal 1, payloads.length
      payloads.first
    end

    def poller(runner, state: FakePollState.new, watched_columns: [], projects: [])
      BasecampAgentConnector::Basecamp::Poller.new \
        basecamp_cli: build_cli(runner), agent: agent_identity, state: state,
        watched_columns: watched_columns, projects: projects, logger: StringIO.new
    end

    # Both account-wide listings are stubbed together: the poller reads them on
    # every round, and a stub left off makes the round fail on a missing command
    # rather than on the behaviour under test.
    def stub_listings(runner, notifications: [], assignments: [])
      runner.stub "notifications list", stdout: envelope("unreads" => notifications, "reads" => [])
      runner.stub "cards list --all-projects --assignee Clawdito", stdout: envelope(assignments)
    end

    def notification(overrides = {})
      {
        "id" => 4940356197,
        "type" => "Mention",
        "created_at" => "2026-08-20T02:03:25.509Z",
        "bucket_name" => "BC5 Calendar",
        "app_url" => APP_URL,
        "creator" => { "id" => 100, "name" => "Operator" }
      }.merge(overrides)
    end

    def assignment_event(overrides = {})
      {
        "id" => 7788,
        "action" => "assignment_changed",
        "created_at" => "2026-08-20T02:04:00.000Z",
        "creator" => { "id" => 100, "name" => "Operator", "email_address" => "operator@example.com" },
        "details" => { "added_person_ids" => [ 200 ] }
      }.merge(overrides)
    end

    def watched_column
      BasecampAgentConnector::Basecamp::WatchedColumn.new(bucket: 222, column: 555)
    end
end

class FakePollState
  def initialize
    @seen = Hash.new { |hash, source| hash[source] = [] }
  end

  def seen?(source, id)
    @seen[source].include?(id.to_s)
  end

  def record(source, id)
    @seen[source] << id.to_s
  end

  def forget(source, id)
    @seen[source].delete id.to_s
  end
end
