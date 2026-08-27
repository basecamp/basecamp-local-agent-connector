require "test_helper"

class CircleTest < Minitest::Test
  Circle = BasecampAgentConnector::Basecamp::Circle

  def test_a_ping_notification_is_told_apart_by_its_section
    assert Circle.ping?(ping_notification)
    refute Circle.ping?(ping_notification("section" => "inbox"))
    refute Circle.ping?({})
  end

  # The app URL a human clicks carries only the circle, and the path it implies
  # resolves to nothing. Both ids live in the subscription URL and nowhere else.
  def test_both_ids_come_from_the_subscription_url
    circle = Circle.from_notification(ping_notification)

    assert_equal CIRCLE_ID, circle.id
    assert_equal TRANSCRIPT_ID, circle.transcript
    assert_equal "Operator + Clawdito", circle.title
  end

  def test_a_notification_without_a_subscription_url_addresses_nothing
    assert_nil Circle.from_notification(ping_notification("subscription_url" => nil))
    assert_nil Circle.from_notification(ping_notification("subscription_url" => "https://3.basecamp.com/000/circles/1"))
  end

  def test_a_circle_survives_a_round_trip_through_state
    assert_equal ping_circle, Circle.from_key(ping_circle.key)
  end

  def test_a_key_that_lost_its_transcript_addresses_nothing
    assert_nil Circle.from_key(CIRCLE_ID.to_s)
    assert_nil Circle.from_key("")
  end

  def test_the_lines_endpoint_is_the_campfire_one
    assert_equal "buckets/#{CIRCLE_ID}/chats/#{TRANSCRIPT_ID}/lines.json", ping_circle.lines_path
    assert_equal "buckets/#{CIRCLE_ID}/chats/#{TRANSCRIPT_ID}/lines.json?page=2", ping_circle.lines_path(page: 2)
  end

  def test_the_subscription_endpoint_names_the_transcript_not_the_circle
    assert_equal "buckets/#{CIRCLE_ID}/recordings/#{TRANSCRIPT_ID}/subscription.json", ping_circle.subscription_path
  end
end
