require "base64"
require "digest"
require "fileutils"
require "json"
require "net/http"
require "securerandom"
require "socket"
require "time"
require "uri"

# The browser path to a bearer token for the hosted Basecamp MCP server.
#
# The MCP server accepts only tokens audienced to it (RFC 8707), and bc3 mints
# those through authorization_code + PKCE alone: a dynamically registered
# client may hold no other grant. So a person signs in once, in a browser, AS
# THE AGENT, and this keeps the refresh token that comes back. Every later
# token is a refresh, with no browser.
#
#   authorize!  register a loopback client (once), print the authorize URL,
#               wait for the redirect, redeem the code, store the refresh token
#   token       refresh, store the rotated refresh token, return the access token
#
# The state file holds a refresh token, so it lives outside any repository,
# mode 0600, and nothing here prints a token.
class BasecampAgentConnector::Cursor::McpAuthorization
  class Error < StandardError; end

  AUTHORIZATION_SERVER = "https://app.basecamp.com"

  # Offline access for the refresh token; mcp for the hosted server's own
  # entitlement; full because the job writes (to-dos, a comment).
  SCOPE = "full mcp offline_access"

  # RFC 8252 §7.3 loopback: bc3 accepts http only for these, and matches the
  # port loosely at authorize time, but a fixed port keeps the redirect the
  # registered one exactly.
  CALLBACK_HOST = "127.0.0.1"
  CALLBACK_PORT = 8765
  CALLBACK_PATH = "/callback"

  def self.state_path_for(agent, dir: ENV.fetch("XDG_CONFIG_HOME", File.join(Dir.home, ".config")))
    File.join(dir, "basecamp-agent-connector", "mcp", "#{agent}.json")
  end

  def initialize(agent:, resource: BasecampAgentConnector::Cursor::Dispatcher::MCP_URL,
    authorization_server: AUTHORIZATION_SERVER, state_path: self.class.state_path_for(agent), out: $stderr)
    @agent = agent
    @resource = resource
    @authorization_server = authorization_server
    @state_path = state_path
    @out = out
  end

  def redirect_uri
    "http://#{CALLBACK_HOST}:#{CALLBACK_PORT}#{CALLBACK_PATH}"
  end

  # The URL a person opens, signed in as the agent. Registers the client the
  # first time; the verifier and state are kept for the redemption.
  def authorize_url(verifier:, state:)
    query = URI.encode_www_form \
      response_type: "code",
      client_id: client_id,
      redirect_uri: redirect_uri,
      scope: SCOPE,
      state: state,
      code_challenge: Base64.urlsafe_encode64(Digest::SHA256.digest(verifier), padding: false),
      code_challenge_method: "S256",
      resource: @resource

    "#{metadata.fetch("authorization_endpoint")}?#{query}"
  end

  def authorize!
    verifier = SecureRandom.urlsafe_base64(48)
    state = SecureRandom.urlsafe_base64(24)
    server = TCPServer.new(CALLBACK_HOST, CALLBACK_PORT)

    @out.puts "Open this in a browser signed in to Basecamp as #{@agent} (a private window keeps your own session out of it):"
    @out.puts
    @out.puts "  #{authorize_url(verifier: verifier, state: state)}"
    @out.puts
    @out.puts "Waiting for the redirect to #{redirect_uri} …"

    params = await_callback(server)
    raise Error, "authorization refused: #{params["error"]} #{params["error_description"]}".strip if params["error"]
    raise Error, "state mismatch; start again" unless params["state"] == state

    store tokens_from(grant_type: "authorization_code", code: params.fetch("code"), redirect_uri: redirect_uri, code_verifier: verifier)
    @out.puts "Stored a refresh token for #{@agent} at #{@state_path}."
  ensure
    server&.close
  end

  # A fresh access token, rotating the stored refresh token as bc3 requires.
  def token
    refresh_token = state["refresh_token"] or raise Error, "no refresh token for #{@agent}; run bin/mcp-authorize #{@agent} first"
    tokens = tokens_from(grant_type: "refresh_token", refresh_token: refresh_token)
    store tokens
    tokens.fetch("access_token")
  end

  private
    def metadata
      @metadata ||= get_json(URI.join(@authorization_server, "/.well-known/oauth-authorization-server"))
    end

    def client_id
      state["client_id"] || register_client
    end

    # RFC 7591. Public, loopback, authorization_code + refresh_token: the only
    # shape bc3 lets a self-registered client hold.
    def register_client
      registration = post_json URI(metadata.fetch("registration_endpoint")), {
        client_name: "Basecamp agent connector (#{@agent}) → Cursor",
        redirect_uris: [ redirect_uri ],
        grant_types: [ "authorization_code", "refresh_token" ],
        response_types: [ "code" ],
        token_endpoint_auth_method: "none"
      }

      registration.fetch("client_id").tap { |id| write_state(state.merge("client_id" => id)) }
    end

    def tokens_from(**form)
      uri = URI(metadata.fetch("token_endpoint"))
      response = Net::HTTP.post_form(uri, form.merge(client_id: client_id, resource: @resource))
      body = JSON.parse(response.body) rescue {}

      unless response.is_a?(Net::HTTPSuccess)
        raise Error, "token endpoint answered #{response.code}: #{body["error"]} #{body["error_description"]}".strip
      end

      body
    end

    def store(tokens)
      write_state state.merge("refresh_token" => tokens.fetch("refresh_token", state["refresh_token"]),
        "scope" => tokens["scope"], "refreshed_at" => Time.now.utc.iso8601)
    end

    def await_callback(server)
      loop do
        socket = server.accept
        request_line = socket.gets.to_s
        path = request_line.split[1].to_s
        uri = URI.parse(path) rescue nil

        if uri&.path == CALLBACK_PATH
          socket.write "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nConnection: close\r\n\r\nDone. You can close this tab.\n"
          socket.close
          return URI.decode_www_form(uri.query.to_s).to_h
        else
          socket.write "HTTP/1.1 404 Not Found\r\nConnection: close\r\n\r\n"
          socket.close
        end
      end
    end

    def state
      @state ||= File.exist?(@state_path) ? JSON.parse(File.read(@state_path)) : {}
    end

    def write_state(new_state)
      FileUtils.mkdir_p(File.dirname(@state_path), mode: 0o700)
      File.write(@state_path, JSON.pretty_generate(new_state), perm: 0o600)
      File.chmod(0o600, @state_path)
      @state = new_state
    end

    def get_json(uri)
      response = Net::HTTP.get_response(uri)
      raise Error, "#{uri} answered #{response.code}" unless response.is_a?(Net::HTTPSuccess)
      JSON.parse(response.body)
    end

    def post_json(uri, payload)
      response = Net::HTTP.post(uri, JSON.generate(payload), "Content-Type" => "application/json")
      body = JSON.parse(response.body) rescue {}

      unless response.is_a?(Net::HTTPSuccess)
        raise Error, "#{uri} answered #{response.code}: #{body["error"]} #{body["error_description"]}".strip
      end

      body
    end
end
