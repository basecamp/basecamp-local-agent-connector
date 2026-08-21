require "test_helper"
require "tmpdir"

class PollStateTest < Minitest::Test
  def test_a_missing_file_starts_empty_rather_than_failing
    in_a_temporary_state_file do |path|
      assert BasecampAgentConnector::PollState.new(path: path).empty?
    end
  end

  def test_what_was_handled_survives_a_restart
    in_a_temporary_state_file do |path|
      state = BasecampAgentConnector::PollState.new(path: path)
      state.record "notifications", 4940356197
      state.save

      assert BasecampAgentConnector::PollState.new(path: path).seen?("notifications", 4940356197)
    end
  end

  # Ids arrive as integers from a listing and as strings from the saved file, and
  # a mismatch would replay every handled event on the next start.
  def test_an_id_read_back_from_disk_matches_the_integer_it_was_recorded_as
    in_a_temporary_state_file do |path|
      state = BasecampAgentConnector::PollState.new(path: path)
      state.record "cards", "901"
      state.save

      assert BasecampAgentConnector::PollState.new(path: path).seen?("cards", 901)
    end
  end

  def test_sources_do_not_bleed_into_each_other
    state = BasecampAgentConnector::PollState.new(path: "/nonexistent/poll-state.json")
    state.record "cards", 901

    refute state.seen?("notifications", 901)
  end

  def test_an_unreadable_file_is_treated_as_a_fresh_start
    in_a_temporary_state_file do |path|
      File.write path, "{ this is not json"

      assert BasecampAgentConnector::PollState.new(path: path).empty?
    end
  end

  def test_the_file_does_not_grow_without_bound
    in_a_temporary_state_file do |path|
      state = BasecampAgentConnector::PollState.new(path: path)
      (BasecampAgentConnector::PollState::IDS_PER_SOURCE + 50).times { |id| state.record "notifications", id }
      state.save

      reloaded = BasecampAgentConnector::PollState.new(path: path)
      assert reloaded.seen?("notifications", BasecampAgentConnector::PollState::IDS_PER_SOURCE + 49)
      refute reloaded.seen?("notifications", 0)
    end
  end

  private
    def in_a_temporary_state_file
      Dir.mktmpdir do |directory|
        yield File.join(directory, "poll-state.json")
      end
    end
end
