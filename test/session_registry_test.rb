require_relative "test_helper"

class SessionRegistryTest < Minitest::Test
  Registry = BasecampAgentConnector::Session::Registry

  def setup
    @directory = Dir.mktmpdir("basecamp-connect-test-sessions")
    @registry = Registry.new(directory: @directory)
  end

  def teardown
    FileUtils.remove_entry @directory, true
  end

  def test_an_unknown_key_has_no_entry
    assert_nil @registry.find("clawdito_222_Kanban-Card_789")
  end

  def test_recording_then_finding_a_session
    record "clawdito_222_Kanban-Card_789", session_id: "09c36f96-a27b-4b60-a78c-39cf65c802f6", repo: "/repo"

    entry = @registry.find("clawdito_222_Kanban-Card_789")

    assert_equal "09c36f96-a27b-4b60-a78c-39cf65c802f6", entry.session_id
    assert_equal "/repo", entry.repo
  end

  # Both ids are kept: the short one is what `claude stop` takes, the full uuid
  # is what `--resume` requires.
  def test_both_ids_are_kept
    record "key", session_id: "09c36f96-a27b-4b60-a78c-39cf65c802f6"

    entry = @registry.find("key")

    assert_equal "09c36f96", entry.short_id
    assert_equal "09c36f96-a27b-4b60-a78c-39cf65c802f6", entry.session_id
    assert_predicate entry, :resumable?
  end

  # A session whose full uuid could not be read back runs and replies, but
  # resuming it by short id would fork a copy — so it is recorded as not yet
  # resumable rather than resumed wrongly.
  def test_a_session_without_a_full_id_is_not_resumable
    @registry.with("key") do
      Registry::Entry.new(key: "key", session_id: nil, short_id: "09c36f96", name: "A card",
        repo: "/repo", created_at: "2026-09-20T00:00:00Z", queue: [])
    end

    refute_predicate @registry.find("key"), :resumable?
  end

  def test_with_hands_the_block_the_current_entry
    record "key", session_id: "uuid-1"
    seen = nil

    @registry.with("key") { |entry| seen = entry and nil }

    assert_equal "uuid-1", seen.session_id
  end

  def test_returning_nil_from_with_leaves_the_entry_alone
    record "key", session_id: "uuid-1"

    @registry.with("key") { nil }

    assert_equal "uuid-1", @registry.find("key").session_id
  end

  def test_forgetting_a_session
    record "key", session_id: "uuid-1"

    @registry.forget "key"

    assert_nil @registry.find("key")
  end

  def test_queueing_a_message_for_a_busy_session
    record "key", session_id: "uuid-1"

    @registry.enqueue "key", "first"
    @registry.enqueue "key", "second"

    assert_equal [ "first", "second" ], @registry.find("key").queue
  end

  def test_queueing_against_an_unknown_key_records_nothing
    @registry.enqueue "key", "first"

    assert_nil @registry.find("key")
  end


  def test_queued_lists_only_sessions_with_something_waiting
    record "quiet", session_id: "uuid-1"
    record "busy", session_id: "uuid-2"
    @registry.enqueue "busy", "hello"

    assert_equal [ "busy" ], @registry.queued.map(&:key)
  end

  # The entry names a resumable session and the repo it runs in. Neither is
  # any other local user's business.
  def test_entries_are_written_private_to_the_operator
    record "key", session_id: "uuid-1"

    assert_equal "700", format("%o", File.stat(@directory).mode & 0o777)
    assert_equal "600", format("%o", File.stat(File.join(@directory, "key.json")).mode & 0o777)
  end

  # A half-written entry costs one re-spawned session; deleting it could orphan
  # a live one, so it is left exactly where it is.
  def test_an_unreadable_entry_reads_as_absent
    File.write File.join(@directory, "key.json"), "{ not json"

    assert_nil @registry.find("key")
  end

  # Two comments on one card arrive on their own webhook threads and race to
  # the same "is there a session yet?" question. Both reading "no" would give
  # the card two sessions, which is the state the lock exists to prevent.
  def test_concurrent_decisions_on_one_key_are_serialized
    opened = []

    threads = 8.times.map do
      Thread.new do
        @registry.with("key") do |entry|
          next nil unless entry.nil?

          opened << Thread.current.object_id
          sleep 0.01
          Registry::Entry.new(key: "key", session_id: "uuid-1", short_id: "uuid", name: "A card",
            repo: "/repo", created_at: "2026-09-20T00:00:00Z", queue: [])
        end
      end
    end
    threads.each(&:join)

    assert_equal 1, opened.length, "more than one thread decided it was the first"
  end

  private
    def record(key, session_id:, repo: "/repo")
      @registry.with(key) do
        Registry::Entry.new(key: key, session_id: session_id, short_id: session_id.split("-").first,
          name: "A card", repo: repo, created_at: "2026-09-20T00:00:00Z", queue: [])
      end
    end
end
