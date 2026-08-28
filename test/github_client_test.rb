require "test_helper"

class GithubClientTest < Minitest::Test
  def test_create_webhook_posts_config_and_events_and_parses_id
    runner = FakeCommandRunner.new
    runner.stub "repos/acme/widgets/hooks", stdout: '{"id":888}'

    hook = build_github_cli(runner).create_webhook(repo: "acme/widgets", url: "https://example.ts.net/gh/x", secret: "s3cret", events: [ "pull_request_review" ])

    assert_equal 888, hook.fetch("id")
    command = runner.commands.first.join(" ")
    assert_includes command, "repos/acme/widgets/hooks -X POST"
    assert_includes command, "config[url]=https://example.ts.net/gh/x"
    assert_includes command, "config[secret]=s3cret"
    assert_includes command, "events[]=pull_request_review"
  end

  def test_delete_webhook_returns_success_flag
    runner = FakeCommandRunner.new
    runner.stub "-X DELETE repos/acme/widgets/hooks/888", exit_status: 0

    assert build_github_cli(runner).delete_webhook(repo: "acme/widgets", id: 888)
  end

  def test_authenticated_login_reads_the_login_gh_is_signed_in_as
    runner = FakeCommandRunner.new
    runner.stub "api user", stdout: JSON.generate("login" => "octocat", "id" => 1)

    assert_equal "octocat", build_github_cli(runner).authenticated_login
    assert_equal [ [ "gh", "api", "user" ] ], runner.commands
  end

  def test_authenticated_login_raises_when_gh_is_signed_out
    runner = FakeCommandRunner.new
    runner.stub "api user", exit_status: 4, stderr: "gh: To use GitHub CLI in automation, set GH_TOKEN"

    assert_raises BasecampAgentConnector::GitHub::Client::Error do
      build_github_cli(runner).authenticated_login
    end
  end

  def test_review_fetches_the_review
    runner = FakeCommandRunner.new
    runner.stub "pulls/12/reviews/7001", stdout: JSON.generate(review_hash)

    review = build_github_cli(runner).review(repo: "acme/widgets", pull_number: 12, id: 7001)

    assert_equal "changes_requested", review.fetch("state")
  end

  def test_raises_on_command_failure
    runner = FakeCommandRunner.new
    runner.stub "pulls/12/reviews/7001", exit_status: 1, stderr: "Not Found"

    assert_raises BasecampAgentConnector::GitHub::Client::Error do
      build_github_cli(runner).review(repo: "acme/widgets", pull_number: 12, id: 7001)
    end
  end
end
