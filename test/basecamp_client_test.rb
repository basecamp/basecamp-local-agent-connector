require "test_helper"

class BasecampClientTest < Minitest::Test
  def test_me_returns_unwrapped_data
    runner = FakeCommandRunner.new
    runner.stub "basecamp me", stdout: envelope("id" => 123, "email_address" => "clawdito@example.com")

    assert_equal 123, build_cli(runner).me.fetch("id")
  end

  def test_me_passes_profile_flag
    runner = FakeCommandRunner.new
    runner.stub "basecamp me", stdout: envelope("id" => 200)

    build_cli(runner).me(profile: "clawdito")

    assert_includes runner.commands.last.join(" "), "--profile clawdito"
  end

  def test_create_webhook_passes_project_and_types
    runner = FakeCommandRunner.new
    runner.stub "webhooks create", stdout: envelope("id" => 555)

    webhook = build_cli(runner).create_webhook(url: "https://example.org/hook/x", project: 222, types: "Comment")

    assert_equal 555, webhook.fetch("id")
    command = runner.commands.first.join(" ")
    assert_includes command, "--project 222"
    assert_includes command, "--types Comment"
  end

  def test_delete_webhook_returns_success_flag
    runner = FakeCommandRunner.new
    runner.stub "webhooks delete", exit_status: 0

    assert build_cli(runner).delete_webhook(id: 555, project: 222)
  end

  def test_raises_on_command_failure
    runner = FakeCommandRunner.new
    runner.stub "basecamp me", exit_status: 1, stderr: "boom"

    assert_raises BasecampAgentConnector::Basecamp::Client::Error do
      build_cli(runner).me
    end
  end

  def test_chats_lists_a_projects_chats
    runner = FakeCommandRunner.new
    runner.stub "chat list", stdout: envelope([ chat_hash ])

    chats = build_cli(runner).chats(project: 222)

    assert_equal 333, chats.first.fetch("id")
    assert_includes runner.commands.first.join(" "), "chat list --project 222"
  end

  def test_chat_lines_fetches_recent_lines_for_a_room
    runner = FakeCommandRunner.new
    runner.stub "chat messages", stdout: envelope([ chat_line ])

    lines = build_cli(runner).chat_lines(project: 222, chat: 333, limit: 25)

    assert_equal 91001, lines.first.fetch("id")
    assert_includes runner.commands.first.join(" "), "chat messages --project 222 --room 333 --limit 25"
  end

  def test_chat_line_fetches_one_line_by_url
    runner = FakeCommandRunner.new
    runner.stub "chat line ", stdout: envelope(chat_line)

    line = build_cli(runner).chat_line("https://example.org/lines/91001.json")

    assert_equal 91001, line.fetch("id")
    assert_includes runner.commands.first.join(" "), "chat line https://example.org/lines/91001.json"
  end
end
