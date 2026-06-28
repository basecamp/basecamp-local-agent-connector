require "test_helper"

class IdentityTest < Minitest::Test
  def test_resolves_current_user
    runner = FakeCommandRunner.new
    runner.stub "basecamp me", stdout: identity_envelope("id" => 123, "email_address" => "clawdito@example.com", "first_name" => "Clawdito", "last_name" => "Agent")
    runner.stub "people show me", stdout: person_envelope(52007412)

    identity = BasecampAgentConnector::Identity.resolve(basecamp_cli: build_cli(runner))

    assert_equal 123, identity.id
    assert_equal "clawdito@example.com", identity.email
    assert_equal "Clawdito", identity.name
    assert_equal 52007412, identity.person_id
  end

  def test_resolves_a_named_profile
    runner = FakeCommandRunner.new
    runner.stub "basecamp me", stdout: identity_envelope("id" => 200, "first_name" => "Clawdito")
    runner.stub "people show me", stdout: person_envelope(52007412)

    identity = BasecampAgentConnector::Identity.resolve(basecamp_cli: build_cli(runner), profile: "clawdito")

    assert_equal "clawdito", identity.profile
    assert_match(/--profile clawdito/, runner.commands.last.join(" "))
  end

  def test_refreshes_once_when_token_expired_then_succeeds
    runner = FakeCommandRunner.new
    runner.stub "basecamp me", exit_status: 1, stderr: "token expired", once: true
    runner.stub "auth refresh", exit_status: 0
    runner.stub "basecamp me", stdout: identity_envelope("id" => 123)
    runner.stub "people show me", stdout: person_envelope(52007412)

    identity = BasecampAgentConnector::Identity.resolve(basecamp_cli: build_cli(runner))

    assert_equal 123, identity.id
    assert_equal 1, runner.commands_matching(/auth refresh/).length
  end

  def test_raises_when_refresh_still_fails
    runner = FakeCommandRunner.new
    runner.stub "basecamp me", exit_status: 1, stderr: "token expired"
    runner.stub "auth refresh", exit_status: 1

    assert_raises BasecampAgentConnector::BasecampCLI::Error do
      BasecampAgentConnector::Identity.resolve(basecamp_cli: build_cli(runner))
    end
  end

  private
    def identity_envelope(identity)
      envelope("identity" => identity)
    end

    def person_envelope(id)
      envelope("id" => id)
    end
end
