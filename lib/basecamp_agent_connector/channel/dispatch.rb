# A single dispatch fetched from the Agent Channel cursor endpoint. Maps the
# server's dispatch payload onto the same emitted shape the webhook transport
# produces, so the driver skill consumes both identically — with the dispatch
# `reason` and `dispatch_id` added.
class BasecampAgentConnector::Channel::Dispatch
  EMITTED_RECORDING_FIELDS = %w[ id type title app_url url content parent bucket ].freeze
  EMITTED_CREATOR_FIELDS = %w[ id name email_address ].freeze

  def self.from_payload(payload)
    new(payload)
  end

  def initialize(payload)
    @payload = payload
  end

  def id
    @payload["id"]
  end

  def to_emitted_hash
    {
      "dispatch_id" => id,
      "reason" => @payload["reason"],
      "event_id" => event["id"],
      "kind" => event["kind"],
      "created_at" => event["created_at"],
      "creator" => creator.slice(*EMITTED_CREATOR_FIELDS),
      "details" => event["details"] || {},
      "recording" => recording.slice(*EMITTED_RECORDING_FIELDS)
    }
  end

  private
    def event
      @payload["event"] || {}
    end

    def recording
      event["recording"] || {}
    end

    def creator
      event["creator"] || {}
    end
end
