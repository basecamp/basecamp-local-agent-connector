require "test_helper"

class WatchedColumnTest < Minitest::Test
  def test_parses_bucket_column_and_creator
    watched = parse("43795599:9956253701:52498414")

    assert_equal 43795599, watched.bucket
    assert_equal 9956253701, watched.column
    assert_equal 52498414, watched.creator
  end

  def test_parses_without_a_creator
    assert_nil parse("43795599:9956253701").creator
  end

  def test_rejects_a_spec_that_is_not_numeric
    error = assert_raises(ArgumentError) { parse("Mobile: On Call:Sentry") }

    assert_match(/BUCKET:COLUMN/, error.message)
  end

  def test_rejects_a_spec_missing_its_column
    assert_raises(ArgumentError) { parse("43795599") }
  end

  def test_matches_a_card_created_in_the_column_by_the_named_creator
    assert parse("222:555:777").matches?(event(card_created_payload))
  end

  def test_does_not_match_another_column
    refute parse("222:556:777").matches?(event(card_created_payload))
  end

  def test_does_not_match_another_bucket
    refute parse("223:555:777").matches?(event(card_created_payload))
  end

  def test_does_not_match_another_creator
    refute parse("222:555:888").matches?(event(card_created_payload))
  end

  def test_matches_any_creator_when_none_is_named
    assert parse("222:555").matches?(event(card_created_payload))
  end

  # An edit to a card already sitting in the column is not a filing, and picking
  # it up would re-trigger the agent every time somebody fixes a typo.
  def test_does_not_match_a_change_to_an_existing_card
    payload = card_created_payload("kind" => "kanban_card_content_changed")

    refute parse("222:555:777").matches?(event(payload))
  end

  private
    def parse(spec)
      BasecampAgentConnector::Basecamp::WatchedColumn.parse(spec)
    end

    def event(payload)
      BasecampAgentConnector::Basecamp::Event.from_payload(payload)
    end
end
