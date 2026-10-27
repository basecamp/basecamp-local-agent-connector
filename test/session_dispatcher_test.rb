require_relative "test_helper"

# A stand-in for the `claude` CLI that records what it was asked to do and can
# be told what each session's state is. The real wrapper is exercised in
# SessionClaudeTest; this one is about the decisions the dispatcher makes.
class FakeClaude
  Spawn = Struct.new(:session_id, :name, :prompt, :cwd, :permission_mode, :model)
  Continuation = Struct.new(:session_id, :prompt, :cwd, :stopped)

  Message = Struct.new(:session_id, :text)

  attr_reader :spawns, :continuations, :stops, :messages
  attr_accessor :states, :spawn_succeeds, :resolvable, :listing_fails, :continues_as, :resume_succeeds, :on_resume,
    :reply_goes_through

  def initialize
    @spawns = []
    @continuations = []
    @stops = []
    @messages = []
    @states = {}
    @reply_goes_through = false
    @spawn_succeeds = true
    @resume_succeeds = true
    @resolvable = true
    @next_id = 0
  end

  # Mirrors the real CLI: it picks the id, and the short form is the first
  # segment of the full uuid.
  def spawn(name:, prompt:, cwd:, permission_mode: nil, model: nil)
    @next_id += 1
    short = format("%08x", @next_id)
    session_id = "#{short}-0000-0000-0000-000000000000"

    @spawns << Spawn.new(session_id, name, prompt, cwd, permission_mode, model)
    @states[session_id] = "working" if @spawn_succeeds

    BasecampAgentConnector::Session::Claude::Spawned.new(
      session_id: (session_id if @spawn_succeeds && @resolvable),
      short_id: (short if @spawn_succeeds),
      result: result(@spawn_succeeds))
  end

  def resolve_session_id(short_id)
    @resolvable ? @spawns.map(&:session_id).find { |id| id.start_with?(short_id) } : nil
  end

  # Continuations are recorded as attempted whether or not they succeed; the
  # result says which. `on_resume` runs mid-continuation, to let a test do
  # something while the dispatcher is in the middle of one.
  def resume(session_id:, prompt:, cwd:)
    @continuations << Continuation.new(session_id, prompt, cwd, false)
    @on_resume&.call
    result(@resume_succeeds)
  end

  def stop_then_resume(session_id:, short_id:, prompt:, cwd:)
    @stops << short_id
    @continuations << Continuation.new(session_id, prompt, cwd, true)
    @on_resume&.call
    result(@resume_succeeds)
  end

  def stop(short_id)
    @stops << short_id
    result(true)
  end

  # nil unless a test sets it: the real CLI names the session it continued, and
  # a fork names a different one.
  def continued_as(_result)
    @continues_as
  end

  # nil when the CLI could not be asked -- the real one cannot tell an empty
  # list from a question that went unanswered unless it says so.
  def resident?(session_id)
    return nil if @listing_fails

    @states.key?(session_id)
  end

  # Both of these read the same listing in the real class, so an unanswerable
  # CLI has to blank both here -- otherwise the double quietly knows things the
  # connector could not have known.
  def state(session_id)
    return nil if @listing_fails

    @states[session_id]
  end

  # nil when the listing cannot be read, as the real one reports it.
  def busy?(session_id)
    return nil if @listing_fails

    state(session_id) == "working"
  end

  # Attempts are recorded whether or not the reply goes through. None do
  # unless a test says so, which is how a box with no daemon behaves.
  def message(session_id:, text:)
    @messages << Message.new(session_id, text)
    @reply_goes_through
  end

  # The session opened for the only card these tests use.
  def only_session_id
    @spawns.first.session_id
  end

  private
    def result(success)
      BasecampAgentConnector::CommandRunner::Result.new(stdout: "", stderr: success ? "" : "boom", exit_status: success ? 0 : 1)
    end
end

class SessionDispatcherTest < Minitest::Test
  def setup
    @directory = Dir.mktmpdir("basecamp-connect-test-dispatch")
    @registry = BasecampAgentConnector::Session::Registry.new(directory: @directory)
    @claude = FakeClaude.new
    @runner = FakeCommandRunner.new
    @runner.stub "boost create", stdout: envelope("id" => 1)
    @runner.stub "comments create", stdout: envelope("id" => 2)
    @log = StringIO.new
  end

  def teardown
    FileUtils.remove_entry @directory, true
  end

  # The happy path, end to end: a mention opens one session, in the repo the
  # project maps to, named after the card.
  def test_a_mention_opens_a_session_in_the_resolved_repo
    assert dispatcher.dispatch(event)

    assert_equal 1, @claude.spawns.length
    assert_equal "/work/bc3", @claude.spawns.first.cwd
    assert_equal "Re: a card", @claude.spawns.first.name
  end

  def test_the_session_is_recorded_against_the_card
    dispatcher.dispatch event

    entry = @registry.find("clawdito_222_Kanban-Card_789")

    assert_equal @claude.only_session_id, entry.session_id
    assert_equal "/work/bc3", entry.repo
  end

  # The receipt is the session's, as its first step, so it can fit the
  # message; the dispatcher posts nothing for a session it opens. The receipt
  # lands as the agent, on the recording that triggered it.
  def test_a_new_session_acks_first_and_the_dispatcher_does_not
    dispatcher.dispatch event

    prompt = @claude.spawns.first.prompt

    assert_empty @runner.commands_matching(/boost create/)
    assert_includes prompt, "basecamp boost create https://3.basecamp.com/000/buckets/222/comments/456.json"
    assert_includes prompt, "--profile clawdito"
    assert_operator prompt.index("Acknowledge this"), :<, prompt.index("Do this, in order")
  end

  def test_the_configured_permission_mode_and_model_reach_the_session
    dispatcher(permission_mode: "plan", model: "opus").dispatch event

    assert_equal "plan", @claude.spawns.first.permission_mode
    assert_equal "opus", @claude.spawns.first.model
  end

  # The point of the whole exercise: the second comment continues the first
  # session instead of opening another.
  def test_a_second_comment_on_the_same_card_continues_the_same_session
    subject = dispatcher
    subject.dispatch event
    @claude.states[@claude.only_session_id] = "done"

    subject.dispatch event("id" => 99002, "recording" => sample_recording("id" => 457, "content" => "<p>and also this</p>"))

    assert_equal 1, @claude.spawns.length
    assert_equal 1, @claude.continuations.length
    assert_equal @claude.only_session_id, @claude.continuations.first.session_id
  end

  # A resident session — even a finished one — has to be stopped first.
  # Resuming one that is still running forks a copy under a new id, which would
  # quietly give the card two sessions.
  def test_continuing_a_resident_session_stops_it_first
    subject = dispatcher
    subject.dispatch event
    @claude.states[@claude.only_session_id] = "done"

    subject.dispatch event("id" => 99002)

    assert_equal [ @claude.only_session_id[0, 8] ], @claude.stops
    assert @claude.continuations.first.stopped
  end

  # A session the CLI no longer lists has nothing to stop and resumes straight
  # from its history.
  def test_continuing_an_exited_session_does_not_stop_it
    subject = dispatcher
    subject.dispatch event
    @claude.states.delete @claude.only_session_id

    subject.dispatch event("id" => 99002)

    assert_empty @claude.stops
    refute @claude.continuations.first.stopped
  end

  # Stopping a session mid-work would throw that work away, so the comment
  # waits instead.
  def test_a_comment_arriving_while_the_session_works_is_queued
    subject = dispatcher
    subject.dispatch event

    subject.dispatch event("id" => 99002, "recording" => sample_recording("id" => 457, "content" => "<p>one more thing</p>"))

    assert_empty @claude.continuations
    assert_equal 1, @registry.find("clawdito_222_Kanban-Card_789").queue.length
  end

  # A busy session is sent a reply, which reaches it between tool calls:
  # nothing is stopped, nothing waits.
  def test_a_comment_arriving_while_the_session_works_is_replied
    @claude.reply_goes_through = true
    subject = dispatcher
    subject.dispatch event

    subject.dispatch event("id" => 99002, "recording" => sample_recording("id" => 457, "content" => "<p>one more thing</p>"))

    assert_equal [ @claude.only_session_id ], @claude.messages.map(&:session_id)
    assert_includes @claude.messages.first.text, "one more thing"
    assert_empty @claude.continuations
    assert_empty @claude.stops
    assert_empty @registry.find("clawdito_222_Kanban-Card_789").queue
    assert_includes @log.string, "replied with activity on"
  end

  # A reply that does not go through: the comment waits exactly as it did
  # before there was a reply to try.
  def test_a_comment_whose_reply_does_not_go_through_is_queued
    subject = dispatcher
    subject.dispatch event

    subject.dispatch event("id" => 99002, "recording" => sample_recording("id" => 457))

    assert_equal 1, @claude.messages.length
    assert_empty @claude.continuations
    assert_equal 1, @registry.find("clawdito_222_Kanban-Card_789").queue.length
  end

  # An idle session is continued as before; the reply is only for a session
  # that cannot be stopped.
  def test_an_idle_session_is_continued_not_messaged
    @claude.reply_goes_through = true
    subject = dispatcher
    subject.dispatch event
    @claude.states[@claude.only_session_id] = "done"

    subject.dispatch event("id" => 99002, "recording" => sample_recording("id" => 457))

    assert_empty @claude.messages
    assert_equal 1, @claude.continuations.length
  end

  # The flusher delivers what it holds with an ordinary resume once the
  # session is free; it does not try the reply again.
  def test_flushing_does_not_retry_the_reply
    subject = dispatcher
    subject.dispatch event
    subject.dispatch event("id" => 99002, "recording" => sample_recording("id" => 457))
    @claude.reply_goes_through = true

    subject.flush

    assert_equal 1, @claude.messages.length
    assert_equal 1, @registry.find("clawdito_222_Kanban-Card_789").queue.length
  end

  def test_queued_comments_are_delivered_once_the_session_is_free
    subject = dispatcher
    subject.dispatch event
    subject.dispatch event("id" => 99002, "recording" => sample_recording("id" => 457, "content" => "<p>one more thing</p>"))
    @claude.states[@claude.only_session_id] = "done"

    subject.flush

    assert_equal 1, @claude.continuations.length
    assert_includes @claude.continuations.first.prompt, "one more thing"
    assert_empty @registry.find("clawdito_222_Kanban-Card_789").queue
  end

  def test_flushing_leaves_a_still_busy_session_alone
    subject = dispatcher
    subject.dispatch event
    subject.dispatch event("id" => 99002, "recording" => sample_recording("id" => 457))

    subject.flush

    assert_empty @claude.continuations
    assert_equal 1, @registry.find("clawdito_222_Kanban-Card_789").queue.length
  end

  # Everything waiting goes in one continuation rather than one each, so a
  # card commented on three times while busy does not get resumed three times.
  def test_everything_queued_is_delivered_in_one_go
    subject = dispatcher
    subject.dispatch event
    subject.dispatch event("id" => 99002, "recording" => sample_recording("id" => 457, "content" => "<p>first follow-up</p>"))
    subject.dispatch event("id" => 99003, "recording" => sample_recording("id" => 458, "content" => "<p>second follow-up</p>"))
    @claude.states[@claude.only_session_id] = "done"

    subject.flush

    assert_equal 1, @claude.continuations.length
    assert_includes @claude.continuations.first.prompt, "first follow-up"
    assert_includes @claude.continuations.first.prompt, "second follow-up"
  end

  def test_different_cards_get_different_sessions
    subject = dispatcher
    subject.dispatch event
    subject.dispatch event("id" => 99002, "recording" => sample_recording("parent" => { "id" => 999, "type" => "Kanban::Card" }))

    assert_equal 2, @claude.spawns.length
    refute_equal @claude.spawns.first.session_id, @claude.spawns.last.session_id
  end

  # The session is running and will reply; it simply cannot be resumed until
  # its full id is known. Recording it is what stops the next comment opening
  # a second session for the same card.
  def test_a_session_whose_id_cannot_be_read_back_is_still_recorded
    @claude.resolvable = false

    dispatcher.dispatch event

    entry = @registry.find("clawdito_222_Kanban-Card_789")

    refute_nil entry
    refute_predicate entry, :resumable?
    assert_equal "00000001", entry.short_id
  end

  # By the time a follow-up arrives the session has certainly been listed, so
  # the id is looked up again and the entry repaired.
  def test_a_missing_session_id_is_resolved_on_the_next_comment
    subject = dispatcher
    @claude.resolvable = false
    subject.dispatch event

    @claude.resolvable = true
    @claude.states[@claude.only_session_id] = "done"
    subject.dispatch event("id" => 99002)

    assert_equal 1, @claude.spawns.length
    assert_equal 1, @claude.continuations.length
    assert_predicate @registry.find("clawdito_222_Kanban-Card_789"), :resumable?
  end

  # Resuming by short id forks a copy, so a session that still has no full id
  # is left alone rather than duplicated.
  def test_an_unresolvable_session_is_never_resumed
    subject = dispatcher
    @claude.resolvable = false
    subject.dispatch event
    @claude.states[@claude.only_session_id] = "done"

    subject.dispatch event("id" => 99002)

    assert_empty @claude.continuations
    assert_equal 1, @claude.spawns.length
  end

  # A card mid-conversation is exactly what a move is meant to push along, so
  # the move lands in the session the card already has — the same key, because
  # a comment's card and a moved card are the same thing of work.
  def test_moving_a_card_that_has_a_session_continues_it
    subject = dispatcher
    subject.dispatch event
    @claude.states[@claude.only_session_id] = "done"

    subject.dispatch moved

    assert_equal 1, @claude.spawns.length
    assert_equal 1, @claude.continuations.length
    assert_includes @claude.continuations.first.prompt, "In progress"
  end

  # Every fork so far logged as an ordinary continue. When the CLI reports that
  # it continued a different session from the one it was given, that is said.
  def test_a_resume_that_lands_in_a_copy_is_named_in_the_log
    subject = dispatcher
    subject.dispatch event
    @claude.states[@claude.only_session_id] = "done"
    @claude.continues_as = "deadbeef"

    subject.dispatch moved

    assert_match(/COPIED into deadbeef/, @log.string)
  end

  def test_a_resume_that_continues_the_same_session_says_nothing_extra
    subject = dispatcher
    subject.dispatch event
    @claude.states[@claude.only_session_id] = "done"
    @claude.continues_as = @claude.only_session_id[0, 8]

    subject.dispatch moved

    refute_match(/COPIED/, @log.string)
  end

  # Resuming a resident session forks it into a copy under a new id, carrying
  # the whole conversation -- one card, two sessions, two replies. So a session
  # the CLI still lists is stopped first.
  def test_a_resident_session_is_stopped_before_it_is_continued
    subject = dispatcher
    subject.dispatch event
    @claude.states[@claude.only_session_id] = "done"

    subject.dispatch moved

    assert_predicate @claude.continuations.last, :stopped
    refute_empty @claude.stops
  end

  # The case that forked a card in production: the connector had just
  # restarted, the first event arrived before `claude agents` could answer, and
  # an unanswered question read as "no such session" -- which took the branch
  # that forks. Not knowing must never resume in place. It now does not resume
  # at all: the move waits until the CLI can say what the session is doing,
  # and is then delivered by stopping first.
  def test_a_session_the_cli_cannot_be_asked_about_is_not_resumed_in_place
    subject = dispatcher
    subject.dispatch event
    @claude.states[@claude.only_session_id] = "done"
    @claude.listing_fails = true

    subject.dispatch moved

    assert_empty @claude.continuations
    assert_equal 1, @registry.find("clawdito_222_Kanban-Card_789").queue.length

    @claude.listing_fails = false
    subject.flush

    assert_predicate @claude.continuations.last, :stopped
    assert_empty @registry.find("clawdito_222_Kanban-Card_789").queue
  end

  # Nothing to stop, so nothing is spent trying.
  def test_a_session_that_is_not_resident_is_resumed_in_place
    subject = dispatcher
    subject.dispatch event
    @claude.states.delete @claude.only_session_id

    subject.dispatch moved

    refute_predicate @claude.continuations.last, :stopped
  end

  # Assignment is how the board says a card is the agent's. Without it, a move
  # is somebody rearranging their own work on a board the agent merely watches.
  def test_moving_an_unassigned_card_with_no_session_does_nothing
    refute dispatcher.dispatch(moved)

    assert_empty @claude.spawns
    assert_empty @runner.commands_matching(/boost create/)
    assert_nil @registry.find("clawdito_222_Kanban-Card_789")
  end

  def test_moving_an_assigned_card_with_no_session_opens_one
    assert dispatcher.dispatch(moved({}, assigned: true))

    assert_equal 1, @claude.spawns.length
    assert_includes @claude.spawns.first.prompt, "In progress"
  end

  # The boost would say "somebody picked this up" about a card nobody did.
  def test_an_ignored_move_leaves_no_receipt_on_the_card
    dispatcher.dispatch moved

    assert_empty @runner.commands_matching(/boost create/)
  end

  def test_an_acted_on_move_is_acknowledged_by_the_session
    dispatcher.dispatch moved({}, assigned: true)

    assert_includes @claude.spawns.first.prompt, "Acknowledge this"
  end

  # The card is what the payload names, and it may be weeks old and already
  # covered in boosts. The move is what asked for the work, and bc3 keeps
  # boosts on events too -- so the receipt lands on the move's own line.
  def test_a_move_is_acknowledged_on_the_move_event_not_the_card
    dispatcher.dispatch moved({}, assigned: true)

    assert_includes @claude.spawns.first.prompt, "--event 99005"
  end

  # Everything else names a recording the requester actually wrote, which is
  # the right thing to boost. No event id goes near those.
  def test_an_ordinary_event_is_acknowledged_on_its_own_recording
    dispatcher.dispatch event

    refute_includes @claude.spawns.first.prompt, "--event"
  end

  # The case that needs the move as its target most. The session already
  # exists, so nothing is opened and the agent posts nothing else -- a boost on
  # the card would be indistinguishable from the one left when the session was
  # opened, and the requester has no way to tell the move registered. Note the
  # move is unassigned here: having the session is what earns it.
  def test_moving_a_card_that_has_a_session_is_acknowledged_on_the_move
    subject = dispatcher
    subject.dispatch event
    @claude.states[@claude.only_session_id] = "done"

    subject.dispatch moved

    assert_includes @claude.continuations.last.prompt, "--event 99005"
  end

  # A move carries no words. Handing over the card's own description would read
  # as the requester repeating the brief, and the agent would redo finished work.
  def test_a_move_is_briefed_as_a_move_not_as_the_cards_description
    dispatcher.dispatch moved({}, assigned: true)

    prompt = @claude.spawns.first.prompt

    assert_includes prompt, "moved into the \"In progress\" column"
    assert_includes prompt, "the move is the request"
    refute_includes prompt, "The date picker is off by one"
  end

  # The column the operator chose is the instruction; shunting the card
  # elsewhere would both override them and erase the signal.
  def test_a_move_tells_the_session_to_leave_the_card_where_it_is
    dispatcher.dispatch moved({}, assigned: true)

    prompt = @claude.spawns.first.prompt

    assert_includes prompt, "Leave the card where it is"
    refute_includes prompt, "cards move"
  end

  def test_a_mention_still_tells_the_session_to_move_the_card_out_of_triage
    dispatcher.dispatch event

    assert_includes @claude.spawns.first.prompt, "cards move"
  end

  # A follow-up is owed a receipt as much as the first message was, and one
  # that reaches the session now gets it from the session.
  def test_a_follow_up_continued_now_is_acked_by_the_session
    subject = dispatcher
    subject.dispatch event
    @claude.states[@claude.only_session_id] = "done"

    subject.dispatch event("id" => 99002, "recording" => sample_recording("id" => 457))

    prompt = @claude.continuations.last.prompt
    assert_empty @runner.commands_matching(/boost create/)
    assert_includes prompt, "basecamp boost create https://3.basecamp.com/000/buckets/222/comments/456.json"
    assert_operator prompt.index("Acknowledge this"), :<, prompt.index("Pick up from what you already know")
  end

  def test_a_follow_up_replied_mid_work_is_acked_by_the_session
    @claude.reply_goes_through = true
    subject = dispatcher
    subject.dispatch event

    subject.dispatch event("id" => 99002, "recording" => sample_recording("id" => 457))

    assert_empty @runner.commands_matching(/boost create/)
    assert_includes @claude.messages.last.text, "Acknowledge this"
  end

  # A held follow-up will not be read until the session is free, which can be
  # many minutes, so the dispatcher posts the receipt now and the session is
  # not asked for a second one.
  def test_a_held_follow_up_is_acked_by_the_dispatcher
    subject = dispatcher
    subject.dispatch event

    subject.dispatch event("id" => 99002, "recording" => sample_recording("id" => 457))

    boosts = @runner.commands_matching(/boost create/)
    assert_equal 1, boosts.length
    assert_includes boosts.first, "https://3.basecamp.com/000/buckets/222/comments/456.json"
    assert_includes boosts.first.join(" "), "--profile clawdito"
    refute_includes @registry.find("clawdito_222_Kanban-Card_789").queue.first, "Acknowledge this"
  end

  def test_a_held_follow_up_whose_boost_failed_is_acked_by_the_session_later
    dispatcher.dispatch event
    fail_boosts

    dispatcher.dispatch event("id" => 99002, "recording" => sample_recording("id" => 457))

    assert_includes @registry.find("clawdito_222_Kanban-Card_789").queue.first, "Acknowledge this"
  end

  # A continuation that did not go through leaves the message queued, which is
  # holding it: the dispatcher acks it.
  def test_a_follow_up_whose_continuation_failed_is_acked_by_the_dispatcher
    subject = dispatcher
    subject.dispatch event
    @claude.states[@claude.only_session_id] = "done"
    @claude.resume_succeeds = false

    subject.dispatch event("id" => 99002, "recording" => sample_recording("id" => 457))

    assert_equal 1, @runner.commands_matching(/boost create/).length
    refute_includes @registry.find("clawdito_222_Kanban-Card_789").queue.first, "Acknowledge this"
  end

  def test_a_held_move_is_acked_on_the_move
    subject = dispatcher
    subject.dispatch event

    subject.dispatch moved

    assert_includes @runner.commands_matching(/boost create/).first.join(" "), "--event 99005"
  end

  # A listing the CLI could not give is not "idle": continuing then would stop
  # a session that may be mid-work. The follow-up waits for the flusher.
  def test_a_follow_up_waits_when_the_sessions_state_cannot_be_read
    subject = dispatcher
    subject.dispatch event
    @claude.listing_fails = true

    subject.dispatch event("id" => 99002, "recording" => sample_recording("id" => 457, "content" => "<p>one more thing</p>"))

    assert_empty @claude.continuations
    assert_empty @claude.stops
    assert_equal 1, @registry.find("clawdito_222_Kanban-Card_789").queue.length
  end

  def test_the_flusher_leaves_a_session_alone_while_its_state_cannot_be_read
    subject = dispatcher
    subject.dispatch event
    subject.dispatch event("id" => 99002, "recording" => sample_recording("id" => 457))
    @claude.states[@claude.only_session_id] = "done"
    @claude.listing_fails = true

    subject.flush

    assert_empty @claude.continuations
    assert_equal 1, @registry.find("clawdito_222_Kanban-Card_789").queue.length
  end

  # A resume that failed delivered nothing, so the follow-up is kept for the
  # flusher rather than logged and lost.
  def test_a_follow_up_whose_resume_fails_is_kept
    subject = dispatcher
    subject.dispatch event
    @claude.states[@claude.only_session_id] = "done"
    @claude.resume_succeeds = false

    subject.dispatch event("id" => 99002, "recording" => sample_recording("id" => 457, "content" => "<p>one more thing</p>"))

    queue = @registry.find("clawdito_222_Kanban-Card_789").queue

    assert_equal 1, queue.length
    assert_includes queue.first, "one more thing"
  end

  def test_a_flush_whose_resume_fails_keeps_every_message
    subject = dispatcher
    subject.dispatch event
    subject.dispatch event("id" => 99002, "recording" => sample_recording("id" => 457, "content" => "<p>first</p>"))
    subject.dispatch event("id" => 99003, "recording" => sample_recording("id" => 458, "content" => "<p>second</p>"))
    @claude.states[@claude.only_session_id] = "done"
    @claude.resume_succeeds = false

    subject.flush

    assert_equal 2, @registry.find("clawdito_222_Kanban-Card_789").queue.length
  end

  # The flusher's check, resume and queue update are one decision under the
  # card's lock. A webhook for the same card arriving mid-flush waits for it,
  # rather than continuing the session in between and then being stopped.
  def test_a_delivery_to_the_same_card_waits_for_a_flush_in_progress
    subject = dispatcher
    subject.dispatch event
    subject.dispatch event("id" => 99002, "recording" => sample_recording("id" => 457))
    @claude.states[@claude.only_session_id] = "done"

    delivery = nil
    blocked = nil
    @claude.on_resume = lambda do
      @claude.on_resume = nil
      delivery = Thread.new { subject.dispatch event("id" => 99003, "recording" => sample_recording("id" => 458)) }
      sleep 0.2
      blocked = delivery.alive?
    end

    subject.flush
    delivery&.join

    assert blocked, "a delivery to the same card ran in the middle of a flush"
  end

  # A mapped repo that does not exist makes the spawn raise before `claude` ever
  # runs. The requester has had no receipt yet, so it has to be reported like
  # any refused spawn, not merely logged.
  def test_a_spawn_that_cannot_even_start_is_reported_on_the_card
    unstartable = Object.new
    def unstartable.run(*, chdir: nil)
      raise Errno::ENOENT, chdir.to_s
    end

    dispatcher(claude: BasecampAgentConnector::Session::Claude.new(command_runner: unstartable)).dispatch event

    assert_equal 1, @runner.commands_matching(/comments create/).length
    assert_nil @registry.find("clawdito_222_Kanban-Card_789")
  end

  # A GitHub review line is about a pull request, not a Basecamp thing of work.
  # It stays on STDOUT for whatever handles reviews.
  def test_a_review_line_dispatches_nothing
    refute dispatcher.dispatch({ "event_id" => 7001, "review_id" => 7001, "repo" => "acme/widgets", "state" => "approved" })

    assert_empty @claude.spawns
  end

  # Nobody can be asked which repo to use, so the event is held with a reply
  # saying so — never dispatched into an arbitrary directory.
  def test_an_unmappable_project_is_held_with_a_reply
    unmappable = event("recording" => sample_recording("bucket" => { "id" => 222, "name" => "Marketing Site" }))

    dispatcher.dispatch unmappable

    assert_empty @claude.spawns
    assert_equal 1, @runner.commands_matching(/comments create/).length
    assert_nil @registry.find("clawdito_222_Kanban-Card_789")
  end

  # A spawn that does not start posts nothing, and from Basecamp that is
  # indistinguishable from a mention that never arrived.
  def test_a_refused_spawn_is_reported_on_the_recording
    @claude.spawn_succeeds = false

    dispatcher.dispatch event

    assert_equal 1, @runner.commands_matching(/comments create/).length
    assert_nil @registry.find("clawdito_222_Kanban-Card_789")
  end

  # A boost is a reaction to work already done; acking it would be noise.
  def test_a_boost_event_gets_no_receipt_boost
    dispatcher.dispatch boost_event

    assert_empty @runner.commands_matching(/boost create/)
    assert_equal 1, @claude.spawns.length
    refute_includes @claude.spawns.first.prompt, "Acknowledge this"
  end

  # A comment on a followed thread is context somebody else is having, not a
  # directive addressed to the agent.
  def test_a_subscribed_thread_comment_gets_no_receipt_boost
    followed = event("recording" => sample_recording("content" => "<p>no mention here</p>"))
    followed["trigger"] = { "mentioned" => false, "subscribed" => true }

    dispatcher.dispatch followed

    assert_empty @runner.commands_matching(/boost create/)
    refute_includes @claude.spawns.first.prompt, "Acknowledge this"
  end

  # A session that could not be opened says so on the recording, which is
  # receipt enough; no boost is added on top.
  def test_a_failed_spawn_is_reported_without_a_boost
    @claude.spawn_succeeds = false

    assert dispatcher.dispatch(event)

    assert_empty @runner.commands_matching(/boost create/)
    assert_equal 1, @runner.commands_matching(/comments create/).length
  end

  # What the session is told is the whole briefing; these are the parts that
  # would silently break the workflow if they went missing.
  def test_the_opening_prompt_carries_the_task_and_the_rules
    dispatcher.dispatch event

    prompt = @claude.spawns.first.prompt

    assert_includes prompt, "@clawdito"
    assert_includes prompt, "please take a look"
    assert_includes prompt, "Operator"
    assert_includes prompt, "EnterWorktree"
    assert_includes prompt, "end your turn"
    # Replies go to the card, not the comment: bc3 has no comment-on-a-comment.
    assert_includes prompt, "card_tables/cards/789"
  end

  def test_the_opening_prompt_leaves_the_agents_own_mention_out_of_the_instruction
    dispatcher.dispatch event

    instruction = @claude.spawns.first.prompt[/What was asked:\n\n(.*?)\n\n##/m, 1]

    refute_includes instruction.to_s, "bc-attachment"
  end

  private
    # Every later receipt boost is refused. Comments still post.
    def fail_boosts
      @runner = FakeCommandRunner.new
      @runner.stub "boost create", stdout: error_envelope("not_found"), exit_status: 2
      @runner.stub "comments create", stdout: envelope("id" => 2)
    end

    def dispatcher(permission_mode: "acceptEdits", model: nil, claude: @claude)
      BasecampAgentConnector::Session::Dispatcher.new(
        agent: "clawdito", basecamp_cli: build_cli(@runner), claude: claude, registry: @registry,
        repos: BasecampAgentConnector::Session::RepoResolver.new(mappings: { "bc5" => "/work/bc3" }),
        permission_mode: permission_mode, model: model, logger: @log)
    end

    def event(overrides = {})
      BasecampAgentConnector::Basecamp::Event.from_payload(sample_payload(overrides)).to_emitted_hash
    end

    # The same card the sample comment hangs off, so a move and a comment on it
    # resolve to one key — which is the point.
    def moved(overrides = {}, assigned: false)
      BasecampAgentConnector::Basecamp::Event.from_payload(
        column_move_payload(overrides.merge("agent_assigned" => assigned))).to_emitted_hash
    end

    def boost_event
      BasecampAgentConnector::Basecamp::Event.from_payload(boost_payload).to_emitted_hash
    end
end
