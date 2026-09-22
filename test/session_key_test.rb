require_relative "test_helper"

class SessionKeyTest < Minitest::Test
  Key = BasecampAgentConnector::Session::Key

  # The rule the whole design rests on: a comment joins the session its card
  # already owns. Get this wrong and every comment opens a session of its own,
  # which is the behaviour this replaces.
  def test_a_comment_keys_on_the_card_it_lives_on
    key = Key.from_event(emitted(sample_recording), agent: "clawdito")

    assert_equal "Kanban::Card", key.type
    assert_equal 789, key.id
  end

  def test_a_mention_in_the_card_itself_keys_on_that_card
    key = Key.from_event(emitted(assigned_recording("id" => 789, "type" => "Kanban::Card")), agent: "clawdito")

    assert_equal "Kanban::Card", key.type
    assert_equal 789, key.id
  end

  # Two comments on one card are one session; the same comment text on another
  # card is not.
  def test_comments_on_the_same_card_share_a_key
    first = Key.from_event(emitted(sample_recording("id" => 456)), agent: "clawdito")
    second = Key.from_event(emitted(sample_recording("id" => 457)), agent: "clawdito")

    assert_equal first, second
    assert_equal first.to_s, second.to_s
  end

  def test_comments_on_different_cards_do_not_share_a_key
    here = Key.from_event(emitted(sample_recording), agent: "clawdito")
    there = Key.from_event(emitted(sample_recording("parent" => { "id" => 999, "type" => "Kanban::Card" })), agent: "clawdito")

    refute_equal here, there
  end

  def test_a_message_keys_on_the_message
    key = Key.from_event(emitted(published_message), agent: "clawdito")

    assert_equal "Message", key.type
    assert_equal 458, key.id
  end

  # A chat line is attached to its room the way a comment is attached to its
  # card, so a Campfire is one session rather than one per line.
  def test_a_chat_line_keys_on_its_room
    key = Key.from_event(emitted(chat_line), agent: "clawdito")

    assert_equal "Chat::Transcript", key.type
    assert_equal 333, key.id
  end

  # Two agents watching one project must not share a session: they are
  # different Basecamp users with different reply identities.
  def test_different_agents_do_not_share_a_key
    mine = Key.from_event(emitted(sample_recording), agent: "clawdito")
    theirs = Key.from_event(emitted(sample_recording), agent: "rhea")

    refute_equal mine, theirs
  end

  # A GitHub review line is about a pull request; there is no Basecamp thing of
  # work to hang a session on, and the dispatcher leaves it to STDOUT.
  def test_an_event_with_no_recording_has_no_key
    assert_nil Key.from_event({ "review_id" => 7001, "repo" => "acme/widgets" }, agent: "clawdito")
  end

  # A truncated payload leaves the recording as its own root rather than
  # dropping the event on the floor.
  def test_a_comment_whose_parent_has_no_id_falls_back_to_itself
    key = Key.from_event(emitted(sample_recording("parent" => { "type" => "Kanban::Card" })), agent: "clawdito")

    assert_equal "Comment", key.type
    assert_equal 456, key.id
  end

  def test_the_key_is_safe_to_use_as_a_filename
    key = Key.from_event(emitted(sample_recording), agent: "clawdito")

    assert_equal "clawdito_222_Kanban-Card_789", key.to_s
    refute_includes key.to_s, "/"
    refute_includes key.to_s, ":"
  end

  # The card's own title is what makes `claude agents` readable at a glance.
  def test_the_display_name_prefers_the_recordings_title
    key = Key.from_event(emitted(published_message), agent: "clawdito")

    assert_equal "Kick off", key.display_name
  end

  def test_the_display_name_falls_back_to_the_type_and_id
    recording = sample_recording("title" => nil, "parent" => { "id" => 789, "type" => "Kanban::Card" })

    assert_equal "Kanban::Card 789", Key.from_event(emitted(recording), agent: "clawdito").display_name
  end

  private
    def emitted(recording)
      BasecampAgentConnector::Basecamp::Event.from_payload(sample_payload("recording" => recording)).to_emitted_hash
    end
end
