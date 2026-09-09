require "test_helper"

class PairingsTest < Minitest::Test
  def setup
    @directory = Dir.mktmpdir
    @pairings = BasecampAgentConnector::Pairings.new(path: File.join(@directory, "pairings.json"))
  end

  def teardown
    FileUtils.rm_rf @directory
  end

  def test_a_request_is_pending_until_paired
    @pairings.request(300, login: "@marie", reply_url: "https://3.basecamp.com/000/buckets/222/comments/900")

    assert_equal "marie", @pairings.pending(300)["login"]
    assert_nil @pairings.find(300)

    @pairings.pair(300, login: "marie", id: 4242, approved_by: 100)

    assert_nil @pairings.pending(300)
    assert_equal({ "login" => "marie", "id" => 4242, "approved_by" => 100 }, @pairings.find(300).slice("login", "id", "approved_by"))
    assert_equal "100600", File.stat(@pairings.path).mode.to_s(8)
  end

  def test_find_is_keyed_on_the_person_id_however_spelled
    @pairings.pair(300, login: "marie", id: 4242, approved_by: 100)

    assert_equal "marie", @pairings.find("300")["login"]
    assert_nil @pairings.find(301)
  end

  # The connector holds one instance for its whole run; a pairing made by
  # bin/pair meanwhile must take effect without a restart.
  def test_reads_pairings_written_by_another_process
    other = BasecampAgentConnector::Pairings.new(path: @pairings.path)
    assert_nil @pairings.find(300)

    other.pair(300, login: "marie", id: 4242, approved_by: 100)

    assert_equal "marie", @pairings.find(300)["login"]
  end

  def test_remove_forgets_paired_and_pending_alike
    @pairings.request(300, login: "marie", reply_url: "u")
    @pairings.pair(301, login: "sam", id: 1, approved_by: 100)

    refute @pairings.remove(300)
    assert @pairings.remove(301)
    assert_nil @pairings.pending(300)
    assert_empty @pairings.paired
  end

  def test_a_missing_or_malformed_file_reads_as_nobody_paired
    assert_empty @pairings.paired
    [ "not json", "[]", '{"paired": [], "pending": 3}', "null" ].each do |contents|
      File.write @pairings.path, contents
      assert_empty BasecampAgentConnector::Pairings.new(path: @pairings.path).paired, contents
      assert_nil BasecampAgentConnector::Pairings.new(path: @pairings.path).find(300), contents
    end
  end

  # The operator approves by boosting the agent's reply, so the approving
  # event carries that reply's URL and not the requester's id.
  def test_a_pending_request_is_found_by_the_reply_it_was_acknowledged_in
    @pairings.request(300, login: "marie", reply_url: "https://3.basecamp.com/000/buckets/222/comments/900")

    found = @pairings.pending_for_reply("https://3.basecamp.com/000/buckets/222/comments/900")

    assert_equal 300, found["person_id"]
    assert_equal "marie", found["login"]
    assert_nil @pairings.pending_for_reply("https://3.basecamp.com/000/buckets/222/comments/901")
    assert_equal [ "300" ], @pairings.pending_requests.keys
  end
end
