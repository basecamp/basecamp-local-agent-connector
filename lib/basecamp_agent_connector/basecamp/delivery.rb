require "json"
require "time"

# One entry of a webhook's delivery history (`recent_deliveries` on the
# webhook), read defensively. bc3 renders the entry, but its body embeds what
# people wrote, and a shape this code did not expect must cost that entry —
# never the read, and never the entries behind it.
BasecampAgentConnector::Basecamp::Delivery = Data.define(:id, :created_at, :attempted_at, :code, :body) do
  # Nil for an entry with no delivery id: there is nothing to know it by.
  def self.from_entry(entry)
    if entry.is_a?(Hash) && !entry["id"].nil?
      new id: entry["id"], created_at: entry["created_at"], attempted_at: parse_time(entry["created_at"]),
        code: response_code(entry), body: request_body(entry)
    end
  end

  def self.response_code(entry)
    response = entry["response"]
    response["code"] if response.is_a?(Hash)
  end

  # The body as the live route would have read it. bc3 renders it decoded,
  # but one recorded as a string is parsed exactly as the route parses the
  # raw POST. Anything that does not come out as an event envelope — a hash
  # carrying the event id the pipeline's suppression is keyed on — is
  # unreadable, and reported rather than guessed at.
  def self.request_body(entry)
    request = entry["request"]
    body = request["body"] if request.is_a?(Hash)
    body = JSON.parse(body) if body.is_a?(String)
    body if body.is_a?(Hash) && !body["id"].nil?
  rescue JSON::ParserError
    nil
  end

  def self.parse_time(value)
    Time.iso8601(value) if value.is_a?(String)
  rescue ArgumentError
    nil
  end

  private_class_method :response_code, :request_body, :parse_time

  def event_id
    body["id"] if body
  end
end
