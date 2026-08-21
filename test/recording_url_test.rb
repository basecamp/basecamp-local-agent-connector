require "test_helper"

class RecordingUrlTest < Minitest::Test
  def test_a_comment_notification_points_at_the_comment_not_the_card_it_lives_on
    assert_equal "https://3.basecampapi.com/2914079/buckets/48348194/comments/222.json",
      from("https://app.basecamp.com/2914079/buckets/48348194/card_tables/cards/111#__recording_222")
  end

  def test_a_notification_without_a_recording_fragment_points_at_the_item_itself
    assert_equal "https://3.basecampapi.com/2914079/buckets/48348194/card_tables/cards/111.json",
      from("https://app.basecamp.com/2914079/buckets/48348194/card_tables/cards/111")
  end

  def test_a_trailing_slash_does_not_produce_a_double_extension
    assert_equal "https://3.basecampapi.com/2914079/buckets/48348194/todos/111.json",
      from("https://app.basecamp.com/2914079/buckets/48348194/todos/111/")
  end

  def test_an_unrecognizable_fragment_is_ignored_rather_than_guessed_at
    assert_equal "https://3.basecampapi.com/2914079/buckets/48348194/messages/111.json",
      from("https://app.basecamp.com/2914079/buckets/48348194/messages/111#something-else")
  end

  def test_nothing_resolves_to_nothing
    assert_nil from(nil)
    assert_nil from("")
  end

  private
    def from(app_url)
      BasecampAgentConnector::Basecamp::RecordingUrl.from_app_url(app_url)
    end
end
