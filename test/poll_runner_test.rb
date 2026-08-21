require "test_helper"

class PollRunnerTest < Minitest::Test
  def test_the_agent_is_taken_from_the_bare_argument_and_normalized
    assert_equal "clawdito", parse("@Clawdito", "--project", "222").agent
  end

  def test_an_agent_is_required
    error = assert_raises(ArgumentError) { parse("--project", "222") }
    assert_match(/an agent is required/, error.message)
  end

  def test_watched_columns_are_parsed_into_specifications
    watched = parse("@clawdito", "--watch-column", "222:555:777").watched_columns.first

    assert_equal 222, watched.bucket
    assert_equal 555, watched.column
    assert_equal 777, watched.creator
  end

  # A round costs several account-wide listings, and nothing being watched moves
  # fast enough to reward hammering them.
  def test_an_interval_below_the_floor_is_refused
    error = assert_raises(ArgumentError) { parse("@clawdito", "--interval", "5") }
    assert_match(/hammers the API/, error.message)
  end

  def test_polling_starts_from_now_unless_backfill_is_asked_for
    refute parse("@clawdito").backfill
    assert parse("@clawdito", "--backfill").backfill
  end

  private
    def parse(*arguments)
      BasecampAgentConnector::PollRunner.parse_options(arguments)
    end
end
