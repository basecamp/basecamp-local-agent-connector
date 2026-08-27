require "test_helper"

class PingsTest < Minitest::Test
  def setup
    @state = fresh_state
  end

  def test_a_new_conversation_is_adopted_and_its_latest_message_emitted
    runner = FakeCommandRunner.new
    stub_notifications runner, [ ping_notification ]
    stub_lines runner, [ ping_line ]

    payloads = build_pings(runner, @state).payloads

    assert_equal 1, payloads.length
    assert_equal BasecampAgentConnector::Basecamp::Pings::KIND, payloads.first["kind"]
    assert_equal 10242670010, payloads.first.dig("recording", "id")
  end

  # The whole reason discovery and reading are separate. One notification per
  # conversation gets re-marked unread as messages arrive, so anything keyed on it
  # answers the first ping in a thread and never another.
  def test_a_second_message_in_the_same_conversation_still_emits
    runner = FakeCommandRunner.new
    stub_notifications runner, [ ping_notification ]
    stub_lines runner, [ ping_line ]
    build_pings(runner, @state).payloads

    # A fresh runner per round, because a stub is never consumed: two rounds
    # asking for the same page on one runner both get the first round's answer.
    runner = FakeCommandRunner.new
    stub_notifications runner, [ ping_notification ]
    stub_lines runner, [ ping_line("id" => 10242740960), ping_line ]

    payloads = build_pings(runner, @state).payloads

    assert_equal [ 10242740960 ], payloads.map { |payload| payload.dig("recording", "id") }
  end

  # Adoption takes the run of his messages at the head and nothing behind it. A
  # conversation that has been going for months would otherwise dispatch an agent
  # per message the moment the bot noticed it.
  def test_adoption_leaves_the_history_behind_the_latest_run_alone
    runner = FakeCommandRunner.new
    stub_notifications runner, [ ping_notification ]
    stub_lines runner, [
      ping_line("id" => 3),
      ping_line("id" => 2),
      agent_line("id" => 1),
      ping_line("id" => 0)
    ]

    payloads = build_pings(runner, @state).payloads

    assert_equal [ 2, 3 ], payloads.map { |payload| payload.dig("recording", "id") },
      "his two latest messages, oldest first; nothing from before the agent's reply"
  end

  def test_messages_are_emitted_oldest_first
    runner = FakeCommandRunner.new
    stub_notifications runner, [ ping_notification ]
    stub_lines runner, [ ping_line("id" => 3), ping_line("id" => 2), ping_line("id" => 1) ]

    payloads = build_pings(runner, @state).payloads

    assert_equal [ 1, 2, 3 ], payloads.map { |payload| payload.dig("recording", "id") }
  end

  # The agent's own replies land in the conversation it is watching. Emitting them
  # would spend a verification round proving the bot wrote what the bot wrote.
  def test_the_agents_own_messages_are_not_emitted_but_are_remembered
    runner = FakeCommandRunner.new
    stub_notifications runner, [ ping_notification ]
    stub_lines runner, [ agent_line("id" => 7) ]
    pings = build_pings(runner, @state)

    assert_empty pings.payloads

    stub_notifications runner, [ ping_notification ]
    stub_lines runner, [ agent_line("id" => 7) ], page: 1

    assert_empty pings.payloads
    assert @state.seen?(BasecampAgentConnector::Basecamp::Pings::LINES, 7)
  end

  def test_a_conversation_is_adopted_once
    runner = FakeCommandRunner.new
    stub_notifications runner, [ ping_notification ]
    stub_lines runner, [ ping_line ]
    build_pings(runner, @state).payloads

    runner = FakeCommandRunner.new
    stub_notifications runner, [ ping_notification ]
    stub_lines runner, [ ping_line ], page: 1

    assert_empty build_pings(runner, @state).payloads
    assert_equal 1, runner.commands_matching(/lines\.json\?page=1 /).length, "one page-one read per round"
  end

  # Pages descend and never overlap, so the walk stops at the first message
  # already handled rather than reading the whole conversation every round.
  def test_the_walk_crosses_pages_until_it_reaches_something_already_seen
    runner = FakeCommandRunner.new
    stub_notifications runner, [ ping_notification ]
    stub_lines runner, [ ping_line("id" => 100) ]
    build_pings(runner, @state).payloads

    runner = FakeCommandRunner.new
    stub_notifications runner, [ ping_notification ]
    stub_lines runner, (105.downto(101)).map { |id| ping_line("id" => id) }
    stub_lines runner, [ ping_line("id" => 100), ping_line("id" => 99) ], page: 2

    payloads = build_pings(runner, @state).payloads

    assert_equal (101..105).to_a, payloads.map { |payload| payload.dig("recording", "id") }
  end

  def test_the_walk_stops_at_the_page_cap
    runner = FakeCommandRunner.new
    stub_notifications runner, [ ping_notification ]
    stub_lines runner, [ ping_line("id" => 1) ]
    build_pings(runner, @state).payloads

    runner = FakeCommandRunner.new
    stub_notifications runner, [ ping_notification ]
    (1..BasecampAgentConnector::Basecamp::Pings::MAX_PAGES).each do |page|
      stub_lines runner, [ ping_line("id" => 1000 + page) ], page: page
    end

    payloads = build_pings(runner, @state).payloads

    assert_equal BasecampAgentConnector::Basecamp::Pings::MAX_PAGES, payloads.length
  end

  # Nothing was emitted, so nothing may stay remembered: the next round has to
  # find the message again rather than lose it to a blip.
  def test_rollback_gives_back_what_the_round_remembered
    runner = FakeCommandRunner.new
    stub_notifications runner, [ ping_notification ]
    stub_lines runner, [ ping_line ]
    pings = build_pings(runner, @state)
    payload = pings.payloads.first

    pings.rollback payload

    refute @state.seen?(BasecampAgentConnector::Basecamp::Pings::LINES, 10242670010)
  end

  def test_seeding_remembers_everything_and_emits_nothing
    runner = FakeCommandRunner.new
    stub_notifications runner, [ ping_notification ]
    stub_lines runner, [ ping_line("id" => 2), ping_line("id" => 1) ]
    pings = build_pings(runner, @state)

    pings.seed

    stub_notifications runner, [ ping_notification ]
    stub_lines runner, [ ping_line("id" => 2), ping_line("id" => 1) ], page: 1

    assert_empty pings.payloads
  end

  def test_a_notification_that_is_not_a_ping_opens_no_conversation
    runner = FakeCommandRunner.new
    stub_notifications runner, [ ping_notification("section" => "inbox") ]

    assert_empty build_pings(runner, @state).payloads
  end

  # A read that failed is not a conversation with nothing in it. Leaving the
  # circle remembered but its lines unremembered is what makes the next round
  # ask again.
  def test_a_failed_read_emits_nothing_and_stays_retryable
    runner = FakeCommandRunner.new
    stub_notifications runner, [ ping_notification ]
    runner.stub "api get #{ping_circle.lines_path(page: 1)} ", stderr: "timed out", exit_status: 1

    assert_empty build_pings(runner, @state).payloads
    refute @state.seen?(BasecampAgentConnector::Basecamp::Pings::LINES, 10242670010)
  end

  def test_an_unreadable_notification_listing_is_survived
    runner = FakeCommandRunner.new
    runner.stub "notifications list", stderr: "timed out", exit_status: 1

    assert_empty build_pings(runner, @state).payloads
  end

  # A ping he has boosted is one he has acted on, so it stops cluttering the
  # conversation. His ruling 2026-08-27.
  def test_a_ping_he_boosted_is_deleted
    runner = FakeCommandRunner.new
    stub_notifications runner, [ ping_notification ]
    stub_lines runner, [ agent_line("id" => 7, "boosts_count" => 1) ]
    stub_boosts runner, 7, [ 100 ]
    runner.stub "api delete #{ping_circle.line_path(7)}", stdout: envelope("ok" => true)

    build_pings(runner, @state).payloads

    assert_equal 1, runner.commands_matching(/api delete .*lines\/7\.json/).length
  end

  # The narrowest part of the rule and the one worth a test of its own: anyone
  # else in a conversation could otherwise delete the bot's side of it.
  def test_a_boost_from_somebody_else_deletes_nothing
    runner = FakeCommandRunner.new
    stub_notifications runner, [ ping_notification ]
    stub_lines runner, [ agent_line("id" => 7, "boosts_count" => 1) ]
    stub_boosts runner, 7, [ 300 ]

    build_pings(runner, @state).payloads

    assert_empty runner.commands_matching(/api delete/)
  end

  # His own messages are his to delete, not the bot's.
  def test_his_own_boosted_message_is_left_alone
    runner = FakeCommandRunner.new
    stub_notifications runner, [ ping_notification ]
    stub_lines runner, [ ping_line("id" => 7, "boosts_count" => 1) ]

    build_pings(runner, @state).payloads

    assert_empty runner.commands_matching(/api delete/)
    assert_empty runner.commands_matching(/boosts\.json/), "no boost read is owed on his own line"
  end

  def test_an_unboosted_ping_costs_no_boost_read
    runner = FakeCommandRunner.new
    stub_notifications runner, [ ping_notification ]
    stub_lines runner, [ agent_line("id" => 7) ]

    build_pings(runner, @state).payloads

    assert_empty runner.commands_matching(/boosts\.json/)
    assert_empty runner.commands_matching(/api delete/)
  end

  # The reaper shares the emitter's read rather than paying for its own.
  def test_the_round_reads_page_one_once
    runner = FakeCommandRunner.new
    stub_notifications runner, [ ping_notification ]
    stub_lines runner, [ ping_line("id" => 9) ]

    build_pings(runner, @state).payloads

    assert_equal 1, runner.commands_matching(/lines\.json\?page=1 /).length
  end

  def test_a_delete_that_fails_is_survived
    runner = FakeCommandRunner.new
    stub_notifications runner, [ ping_notification ]
    stub_lines runner, [ agent_line("id" => 7, "boosts_count" => 1) ]
    stub_boosts runner, 7, [ 100 ]
    runner.stub "api delete", stderr: "timed out", exit_status: 1

    build_pings(runner, @state).payloads
  end

  # The one path that could re-emit an already-dispatched message: adoption reads
  # the head run rather than the line memory, so a circle key lost while its line
  # ids survived would replay his latest question at a fresh agent.
  def test_adoption_does_not_re_emit_a_message_already_handled
    runner = FakeCommandRunner.new
    stub_notifications runner, [ ping_notification ]
    stub_lines runner, [ ping_line("id" => 8), ping_line("id" => 7) ]
    build_pings(runner, @state).payloads

    @state.forget BasecampAgentConnector::Basecamp::Pings::CIRCLES, ping_circle.key

    runner = FakeCommandRunner.new
    stub_notifications runner, [ ping_notification ]
    stub_lines runner, [ ping_line("id" => 8), ping_line("id" => 7) ]

    assert_empty build_pings(runner, @state).payloads,
      "the circle is re-adopted, but both messages are already remembered"
  end
end
