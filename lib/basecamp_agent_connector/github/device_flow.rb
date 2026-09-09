require "json"
require "net/http"
require "openssl"
require "uri"

# GitHub's OAuth device flow, used for one thing: proving that the person
# pairing controls the GitHub login they declared. The flow needs only a
# client id (an OAuth App with device flow enabled; no secret, no scopes),
# the person enters a short code in their own browser, and the resulting
# token is used once, for `GET /user`, then dropped. No token is stored
# anywhere, so there is nothing to refresh, revoke, or leak.
class BasecampAgentConnector::GitHub::DeviceFlow
  class Failed < StandardError; end

  DEFAULT_CONFIG = File.expand_path("~/.config/basecamp-connect/github-oauth.json")
  TIMEOUT = 15 * 60

  Code = Data.define(:device_code, :user_code, :verification_uri, :expires_in, :interval)
  Identity = Data.define(:login, :id)

  def self.client_id(path = DEFAULT_CONFIG)
    JSON.parse(File.read(path))["client_id"] or raise Failed, "no client_id in #{path}"
  rescue Errno::ENOENT
    raise Failed, "no GitHub OAuth client id at #{path}: run `bin/pair setup --client-id <id>` (README → Pairing)"
  end

  def initialize(client_id:, http: method(:post_json), clock: -> { Time.now }, sleeper: ->(seconds) { sleep seconds })
    @client_id = client_id
    @http = http
    @clock = clock
    @sleeper = sleeper
  end

  def start
    answer = @http.call("https://github.com/login/device/code", { "client_id" => @client_id })
    raise Failed, "device flow could not start: #{answer["error_description"] || answer["error"] || answer.inspect}" if answer["device_code"].nil?

    Code.new device_code: answer["device_code"], user_code: answer["user_code"], verification_uri: answer["verification_uri"],
      expires_in: answer["expires_in"].to_i, interval: [ answer["interval"].to_i, 1 ].max
  end

  # Blocks until the person consents, the code expires, or they decline.
  # Returns the identity that consented; the token never leaves this method.
  def wait(code)
    interval = code.interval
    deadline = @clock.call + [ code.expires_in, TIMEOUT ].reject(&:zero?).min

    while @clock.call < deadline
      @sleeper.call(interval)
      answer = @http.call("https://github.com/login/oauth/access_token",
        { "client_id" => @client_id, "device_code" => code.device_code, "grant_type" => "urn:ietf:params:oauth:grant-type:device_code" })

      case answer["error"]
      when nil then return identity(answer.fetch("access_token"))
      when "authorization_pending" then next
      when "slow_down" then interval += 5
      when "expired_token" then raise Failed, "the code expired before anyone entered it"
      when "access_denied" then raise Failed, "consent was declined in the browser"
      else raise Failed, "device flow failed: #{answer["error_description"] || answer["error"]}"
      end
    end

    raise Failed, "nobody entered the code within #{TIMEOUT / 60} minutes"
  end

  private
    def identity(token)
      user = @http.call("https://api.github.com/user", nil, token: token)
      raise Failed, "GitHub did not identify the token's user: #{user.inspect}" if user["login"].nil?

      Identity.new login: user["login"], id: user["id"]
    end

    # A POST with a JSON body, or a GET when the body is nil, answered as JSON.
    def post_json(url, body, token: nil)
      uri = URI(url)
      request = body.nil? ? Net::HTTP::Get.new(uri) : Net::HTTP::Post.new(uri)
      request["Accept"] = "application/json"
      request["User-Agent"] = "basecamp-agent-connector"
      request["Authorization"] = "Bearer #{token}" unless token.nil?
      unless body.nil?
        request["Content-Type"] = "application/json"
        request.body = JSON.generate(body)
      end
      response = Net::HTTP.start(uri.host, uri.port, use_ssl: true, open_timeout: 10, read_timeout: 30) { |http| http.request(request) }
      JSON.parse(response.body)
    rescue JSON::ParserError
      { "error" => "malformed", "error_description" => response&.body.to_s[0, 200] }
    rescue SystemCallError, SocketError, IOError, Timeout::Error, OpenSSL::SSL::SSLError => error
      # `bin/pair approve` promises the front thread an {"error"} line, never a
      # stack trace, so the network's failures surface the way GitHub's do.
      raise Failed, "could not reach #{uri.host}: #{error.message}"
    end
end
