require_relative "test_helper"

class SessionRepoResolverTest < Minitest::Test
  Resolver = BasecampAgentConnector::Session::RepoResolver

  def setup
    @directory = Dir.mktmpdir("basecamp-connect-test-repos")
  end

  def teardown
    FileUtils.remove_entry @directory, true
  end

  def test_matching_a_token_in_the_project_name
    resolver = build(<<~TOML)
      [mappings]
      "bc5" = "/work/bc3"
      "fizzy" = "/work/fizzy"
    TOML

    assert_equal "/work/bc3", resolver.resolve("BC5 Calendar")
    assert_equal "/work/fizzy", resolver.resolve("Fizzy")
  end

  def test_matching_ignores_case
    resolver = build(%([mappings]\n"bc5" = "/work/bc3"\n))

    assert_equal "/work/bc3", resolver.resolve("bc5 calendar")
    assert_equal "/work/bc3", resolver.resolve("BC5 CALENDAR")
  end

  # The order in the file is the precedence, which is what lets a more specific
  # token sit above a more general one that would also match.
  def test_the_first_matching_token_wins
    resolver = build(<<~TOML)
      [mappings]
      "bc5" = "/work/bc5"
      "basecamp" = "/work/bc3"
    TOML

    assert_equal "/work/bc5", resolver.resolve("BC5 Basecamp Calendar")
  end

  # Nothing matched means the connector holds the event and says so, rather
  # than running an agent in some arbitrary directory.
  def test_an_unmatched_project_resolves_to_nothing
    resolver = build(%([mappings]\n"bc5" = "/work/bc3"\n))

    assert_nil resolver.resolve("Marketing Site")
  end

  def test_a_blank_project_name_resolves_to_nothing
    resolver = build(%([mappings]\n"bc5" = "/work/bc3"\n))

    assert_nil resolver.resolve(nil)
    assert_nil resolver.resolve("")
  end

  def test_paths_are_expanded
    resolver = build(%([mappings]\n"bc5" = "~/work/bc3"\n))

    assert_equal File.expand_path("~/work/bc3"), resolver.resolve("BC5 Calendar")
  end

  def test_comments_and_blank_lines_are_ignored
    resolver = build(<<~TOML)
      # Project -> repo mapping.

      [mappings]
      # the calendar app
      "bc5" = "/work/bc3"
    TOML

    assert_equal 1, resolver.mappings.length
    assert_equal "/work/bc3", resolver.resolve("BC5 Calendar")
  end

  # A file that later grows a second table must not have it silently folded
  # into the mappings.
  def test_only_the_mappings_table_is_read
    resolver = build(<<~TOML)
      [mappings]
      "bc5" = "/work/bc3"

      [something_else]
      "hey" = "/work/nope"
    TOML

    assert_nil resolver.resolve("Hey")
    assert_equal 1, resolver.mappings.length
  end

  def test_a_missing_file_resolves_to_nothing
    resolver = Resolver.new(path: File.join(@directory, "absent.toml"))

    refute_predicate resolver, :any?
    assert_nil resolver.resolve("BC5 Calendar")
  end

  # The mapping the repo ships should parse — a resolver that silently reads
  # nothing would hold every event on a real machine.
  def test_the_shipped_mapping_file_parses
    resolver = Resolver.new

    assert_predicate resolver, :any?
    assert_equal File.expand_path("~/Work/basecamp/bc3"), resolver.resolve("BC5 Calendar")
  end

  private
    def build(contents)
      path = File.join(@directory, "project_repos.toml")
      File.write path, contents
      Resolver.new(path: path)
    end
end
