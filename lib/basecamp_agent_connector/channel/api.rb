require "json"
require "net/http"

# Talks to the Agent Channel REST endpoints as the connected (operator, agent)
# pair, authenticating with the per-connection token. HTTP is reached through an
# injectable client so tests can drive it without a live server.
class BasecampAgentConnector::Channel::Api
  class Error < StandardError; end

  CONNECTION_TOKEN_SCHEME = "Agent-Connection".freeze

  def initialize(base_url:, connection_token:, http: Net::HTTP)
    @base_url = base_url.chomp("/")
    @connection_token = connection_token
    @http = http
  end

  def dispatches(after:, limit: nil)
    query = { after: after }
    query[:limit] = limit if limit
    uri = uri_for("/my/agent/dispatches", query)
    body = request(Net::HTTP::Get.new(uri), uri).body

    JSON.parse(body).map { |payload| BasecampAgentConnector::Channel::Dispatch.from_payload(payload) }
  end

  def ack(dispatch_id)
    uri = uri_for("/my/agent/dispatches/#{dispatch_id}")
    request(Net::HTTP::Put.new(uri), uri)
  end

  private
    def request(message, uri)
      message["Authorization"] = "#{CONNECTION_TOKEN_SCHEME} #{@connection_token}"
      message["User-Agent"] = "Basecamp Agent Connector"

      response = @http.start(uri.host, uri.port, use_ssl: uri.scheme == "https") do |connection|
        connection.request(message)
      end

      unless response.is_a?(Net::HTTPSuccess)
        raise Error, "#{message.method} #{uri.path} failed: #{response.code}"
      end

      response
    end

    def uri_for(path, query = {})
      uri = URI("#{@base_url}#{path}")
      uri.query = URI.encode_www_form(query) unless query.empty?
      uri
    end
end
