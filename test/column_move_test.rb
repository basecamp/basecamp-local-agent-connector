require_relative "test_helper"

# Moving a card into another column as a trigger: the board's own gesture for
# "now do this", on a board where the column says what kind of work is wanted.
class ColumnMoveEventTest < Minitest::Test
  Event = BasecampAgentConnector::Basecamp::Event

  def test_a_card_adoption_is_the_column_move_kind
    assert_predicate event, :column_move?
    assert_predicate event, :actionable_kind?
  end

  # Todos are re-parented by the same verb, but moving a todo between two lists
  # says nothing about what work is wanted — which is why this matches one
  # exact kind rather than an `_adopted` suffix.
  def test_a_todo_adoption_is_not_a_column_move
    moved_todo = Event.from_payload(column_move_payload("kind" => "todo_adopted"))

    refute_predicate moved_todo, :column_move?
  end

  def test_the_destination_column_is_the_recordings_parent
    assert_equal "In progress", event.column_title
    assert_equal 555, event.column["id"]
  end

  # bc3 marks Done and Not-now columns by type, so this holds however they are
  # titled, renamed or translated.
  def test_moves_into_done_and_not_now_columns_are_not_requests_for_work
    %w[Kanban::DoneColumn Kanban::NotNowColumn].each do |type|
      moved = event(recording: moved_card("parent" => column(id: 555, title: "Anything At All", type: type)))

      assert_predicate moved, :moved_into_unworked_column?
    end
  end

  def test_a_plain_column_is_a_request_for_work
    refute_predicate event, :moved_into_unworked_column?
  end

  def test_a_column_can_also_be_excluded_by_title
    assert event.moved_into_unworked_column?([ "In progress" ])
    refute event.moved_into_unworked_column?([ "Somewhere else" ])
  end

  def test_title_exclusion_ignores_case
    assert event.moved_into_unworked_column?([ "in PROGRESS" ])
  end

  # bc3 emits the adoption whenever a card acquires a parent, which includes
  # landing back where it already was. Nothing was asked for there.
  def test_landing_back_in_the_same_column_is_not_a_change
    refute_predicate event(details: { "new_parent_id" => 555, "parent_id_was" => 555 }), :changed_column?
  end

  def test_moving_between_columns_is_a_change
    assert_predicate event, :changed_column?
  end

  # A watcher needs both ids to tell a move from a re-save, so they survive the
  # slice into the emitted line.
  def test_the_emitted_event_carries_both_column_ids
    details = event.to_emitted_hash["details"]

    assert_equal 554, details["parent_id_was"]
    assert_equal 555, details["new_parent_id"]
  end

  def test_the_emitted_event_announces_the_move
    assert event.to_emitted_hash.dig("trigger", "moved")
    refute Event.from_payload(sample_payload).to_emitted_hash.dig("trigger", "moved")
  end

  private
    def event(recording: nil, details: nil)
      overrides = {}
      overrides["recording"] = recording unless recording.nil?
      overrides["details"] = details unless details.nil?

      Event.from_payload(column_move_payload(overrides))
    end
end

class ColumnMoveAuthorizerTest < Minitest::Test
  def test_the_operator_may_move_a_card_to_trigger_the_agent
    assert authorizer.authorizes?(move_by(operator_identity))
  end

  # The agent moves cards itself as work progresses — into In progress when it
  # starts, into For Review when a PR is open. Those moves are authored by the
  # agent, so this is what stops a board gesture it made from waking it again.
  def test_the_agents_own_move_never_triggers_it
    refute authorizer.authorizes?(move_by(agent_identity))
  end

  # A move starts work and anyone who can see a board can drag a card across
  # it, so it is held to the same operator-only rule as an assignment.
  def test_a_broadened_mode_does_not_admit_another_authors_move
    trusted = BasecampAgentConnector::Basecamp::Identity.new(id: 300, email: "marie@example.com", person_id: 300)
    broadened = authorizer(trust: :allowlist, emails: [ "marie@example.com" ])

    refute broadened.authorizes?(move_by(trusted))
  end

  def test_allow_assignments_opts_a_broadened_modes_authors_into_moves_too
    trusted = BasecampAgentConnector::Basecamp::Identity.new(id: 300, email: "marie@example.com", person_id: 300)
    broadened = authorizer(trust: :allowlist, emails: [ "marie@example.com" ], allow_assignments: true)

    assert broadened.authorizes?(move_by(trusted))
  end

  private
    def move_by(identity)
      BasecampAgentConnector::Basecamp::Event.from_payload(column_move_payload(
        "creator" => { "id" => identity.person_id, "name" => "Someone", "email_address" => identity.email }))
    end
end

class ColumnMovePipelineTest < Minitest::Test
  def setup
    @output = StringIO.new
    @log = StringIO.new
  end

  # Off unless asked for: on a board nobody set up for this, every drag would
  # wake the agent.
  def test_a_move_triggers_nothing_by_default
    process column_move_payload, column_moves: false

    assert_empty @output.string
  end

  def test_a_move_into_a_working_column_is_emitted
    process column_move_payload

    assert_equal "kanban_card_adopted", emitted["kind"]
    assert emitted.dig("trigger", "moved")
    assert_equal "In progress", emitted.dig("recording", "parent", "title")
  end

  def test_a_move_into_a_done_column_is_dropped
    process column_move_payload("recording" => moved_card("parent" => column(id: 555, title: "Done", type: "Kanban::DoneColumn")))

    assert_empty @output.string
  end

  def test_a_move_into_a_not_now_column_is_dropped
    process column_move_payload("recording" => moved_card("parent" => column(id: 555, title: "Not now", type: "Kanban::NotNowColumn")))

    assert_empty @output.string
  end

  def test_a_move_into_a_column_excluded_by_title_is_dropped
    process column_move_payload, column_move_except: [ "In progress" ]

    assert_empty @output.string
  end

  def test_a_card_re_saved_in_the_column_it_already_sat_in_is_dropped
    process column_move_payload("details" => { "new_parent_id" => 555, "parent_id_was" => 555 })

    assert_empty @output.string
  end

  # The move is corroborated against the board, not against the payload: the
  # card must actually sit in the column the event claims. A forged POST cannot
  # move a real card.
  def test_a_move_the_board_does_not_agree_with_is_dropped
    process column_move_payload, recording: moved_card("parent" => column(id: 999, title: "Somewhere else"))

    assert_empty @output.string
    assert_match(/not corroborated|does not target/, @log.string)
  end

  # The forgery a current-column check alone lets through: nothing is moved,
  # the POST just claims a move into the column the card already sits in. The
  # card's history has no such event, so it is dropped.
  def test_a_move_the_cards_history_never_recorded_is_dropped
    process column_move_payload, history: []

    assert_empty @output.string
    assert_match(/not corroborated/, @log.string)
  end

  def test_an_event_that_is_not_an_adoption_is_dropped
    process column_move_payload, history: [ adoption("action" => "content_changed") ]

    assert_empty @output.string
  end

  def test_an_adoption_into_a_different_column_than_claimed_is_dropped
    process column_move_payload, history: [ adoption("details" => { "new_parent_id" => 999, "parent_id_was" => 554 }) ]

    assert_empty @output.string
  end

  # The POST's author is a claim. The history's is a fact, and the second
  # authorization runs on it.
  def test_a_move_the_history_says_somebody_else_made_is_dropped
    someone = { "id" => 777, "name" => "Someone Else", "email_address" => "someone@example.com" }

    process column_move_payload, history: [ adoption("creator" => someone) ]

    assert_empty @output.string
    assert_match(/not authorized/, @log.string)
  end

  # The columns on both sides come from the history too, so a POST cannot
  # invent a `parent_id_was` to turn a card that never moved into a move.
  def test_the_columns_acted_on_come_from_the_history_not_the_post
    process column_move_payload, history: [ adoption("details" => { "new_parent_id" => 555, "parent_id_was" => 555 }) ]

    assert_empty @output.string
  end

  # The author of a move is whoever dragged the card, which is not generally
  # whoever created it — so corroborating on the creator, as a mention does,
  # would drop every move of somebody else's card.
  def test_a_move_of_a_card_somebody_else_created_is_emitted
    process column_move_payload

    assert_equal "Operator", emitted.dig("creator", "name")
  end

  def test_the_agents_own_move_is_dropped
    process column_move_payload("creator" => { "id" => 200, "name" => "Clawdito", "email_address" => "clawdito@example.com" })

    assert_empty @output.string
  end

  # Assignment is what says a card is the agent's, and it rides along so the
  # dispatcher can decide whether a move may open a new session.
  def test_the_emitted_move_reports_whether_the_agent_is_an_assignee
    process column_move_payload, recording: moved_card("assignees" => [ { "id" => 200, "name" => "Clawdito" } ])

    assert emitted.dig("trigger", "assigned")
  end

  def test_a_move_of_a_card_the_agent_is_not_on_reports_assigned_false
    process column_move_payload

    refute emitted.dig("trigger", "assigned")
  end

  private
    # `history` is the card's event history as bc3 reports it. By default it
    # holds the adoption the payload claims, as a genuine move would.
    def process(payload, column_moves: true, column_move_except: [], recording: nil, history: [ adoption ])
      runner = FakeCommandRunner.new
      runner.stub "basecamp show", stdout: envelope(recording || payload["recording"] || moved_card)
      runner.stub "recordings/789/events.json", stdout: envelope(history)

      BasecampAgentConnector::Basecamp::Pipeline.new(
        authorizer: authorizer, agent: agent_identity,
        verifier: BasecampAgentConnector::Basecamp::Verifier.new(basecamp_cli: build_cli(runner), agent: agent_identity),
        emitter: BasecampAgentConnector::Emitter.new(output: @output), logger: @log,
        column_moves: column_moves, column_move_except: column_move_except).process(payload)
    end

    def emitted
      JSON.parse(@output.string.lines.first.to_s)
    end

    # The event a real move leaves in the card's history, matching
    # column_move_payload: same id, by the operator, 554 → 555.
    def adoption(overrides = {})
      {
        "id" => 99005, "action" => "adopted", "created_at" => "2026-09-21T19:41:35Z",
        "creator" => { "id" => 100, "name" => "Operator", "email_address" => "operator@example.com" },
        "details" => { "new_parent_id" => 555, "parent_id_was" => 554, "notified_recipient_ids" => [] }
      }.merge(overrides)
    end
end
