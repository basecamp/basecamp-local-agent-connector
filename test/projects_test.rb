require "test_helper"

class ProjectsTest < Minitest::Test
  def test_an_id_or_a_url_needs_no_lookup
    runner = FakeCommandRunner.new

    ids = resolve([ "48806025", "https://3.basecamp.com/2914079/projects/49180808", "https://3.basecamp.com/2914079/buckets/1/chats/2" ], runner)

    assert_equal %w[48806025 49180808 1], ids
    assert_empty runner.commands
  end

  def test_an_exact_name_resolves_to_its_id_with_one_lookup_for_all_names
    runner = listing({ "id" => 222, "name" => "Ops" }, { "id" => 223, "name" => "Ops East" })

    assert_equal %w[222 223], resolve([ "Ops", "Ops East" ], runner)
    assert_equal 1, runner.commands_matching(/projects list/).length
  end

  # Round 1 of PR #61: a chat-less "Ops" must never settle on "Ops East".
  # Case variants and substrings are near matches, named, never taken.
  def test_a_name_without_an_exact_match_is_refused_naming_the_near_ones
    runner = listing({ "id" => 223, "name" => "Ops East" }, { "id" => 224, "name" => "Billing" })

    %w[Ops ops OPS\ EAST].each do |name|
      error = assert_raises(BasecampAgentConnector::Basecamp::Projects::Unresolved) { resolve([ name ], runner) }
      assert_match(/No project is named exactly "#{name}"; near matches: Ops East \(223\)\./, error.message)
      refute_match(/Billing/, error.message)
    end
  end

  def test_a_name_with_no_near_match_says_only_that
    error = assert_raises(BasecampAgentConnector::Basecamp::Projects::Unresolved) do
      resolve([ "Queenbee" ], listing({ "id" => 224, "name" => "Billing" }))
    end

    assert_equal 'No project is named exactly "Queenbee". Pass its exact name, its id, or its URL.', error.message
  end

  # Round 2 of PR #61: two projects named "Ops", one without a Campfire. The
  # full project list sees both, so the name is refused rather than guessed.
  def test_a_name_two_projects_share_is_refused_naming_both
    error = assert_raises(BasecampAgentConnector::Basecamp::Projects::Unresolved) do
      resolve([ "Ops" ], listing({ "id" => 222, "name" => "Ops" }, { "id" => 223, "name" => "Ops" }))
    end

    assert_match(/"Ops" names 2 projects: 222, 223/, error.message)
  end

  private
    def listing(*projects)
      FakeCommandRunner.new.tap { |runner| runner.stub "projects list --all", stdout: envelope(projects) }
    end

    def resolve(tokens, runner)
      BasecampAgentConnector::Basecamp::Projects.resolve(tokens, basecamp_cli: build_cli(runner))
    end
end
