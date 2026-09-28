require "test_helper"
require "tmpdir"

class CursorMcpAuthorizationTest < Minitest::Test
  METADATA = {
    "authorization_endpoint" => "https://bc.test/oauth/authorizations/new",
    "token_endpoint" => "https://bc.test/oauth/tokens",
    "registration_endpoint" => "https://bc.test/oauth/clients"
  }.freeze

  def setup
    @dir = Dir.mktmpdir
    @state_path = File.join(@dir, "mcp", "marie.json")
    FileUtils.mkdir_p(File.dirname(@state_path))
    File.write(@state_path, JSON.generate("client_id" => "dcr_test"))

    @authorization = BasecampAgentConnector::Cursor::McpAuthorization.new(agent: "marie", state_path: @state_path, out: StringIO.new)
    @authorization.instance_variable_set(:@metadata, METADATA)
  end

  def teardown
    FileUtils.remove_entry(@dir)
  end

  def test_authorize_url_asks_for_an_mcp_audienced_code_with_pkce
    url = URI(@authorization.authorize_url(verifier: "v" * 64, state: "s"))
    params = URI.decode_www_form(url.query).to_h

    assert_equal "https://bc.test/oauth/authorizations/new", "#{url.scheme}://#{url.host}#{url.path}"
    assert_equal "dcr_test", params["client_id"]
    assert_equal "https://mcp.basecamp.com/mcp", params["resource"]
    assert_equal "http://127.0.0.1:8765/callback", params["redirect_uri"]
    assert_equal "S256", params["code_challenge_method"]
    assert_equal Base64.urlsafe_encode64(Digest::SHA256.digest("v" * 64), padding: false), params["code_challenge"]
    assert_includes params["scope"].split, "offline_access"
  end

  def test_a_beta_resource_rides_the_same_ceremony
    beta = BasecampAgentConnector::Cursor::McpAuthorization.new(agent: "marie", state_path: @state_path,
      resource: "https://beta3-mcp.3.bc4-beta.com/mcp", out: StringIO.new)
    beta.instance_variable_set(:@metadata, METADATA)

    params = URI.decode_www_form(URI(beta.authorize_url(verifier: "v" * 64, state: "s")).query).to_h

    assert_equal "https://beta3-mcp.3.bc4-beta.com/mcp", params["resource"]
  end

  def test_token_needs_a_prior_authorization
    error = assert_raises(BasecampAgentConnector::Cursor::McpAuthorization::Error) { @authorization.token }

    assert_match "bin/mcp-authorize marie", error.message
  end

  def test_state_path_is_outside_the_repository
    path = BasecampAgentConnector::Cursor::McpAuthorization.state_path_for("marie", dir: "/home/x/.config")

    assert_equal "/home/x/.config/basecamp-agent-connector/mcp/marie.json", path
  end
end
