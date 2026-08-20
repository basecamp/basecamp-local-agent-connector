# A card-table column whose new cards trigger the agent on their own.
#
# Every other path makes the operator the trust root: the event is actionable
# only because he authored it, by mentioning the agent or assigning it. This one
# deliberately does not, because the cards worth catching are filed by a robot —
# Sentry crash reports land in a column nobody watches, and requiring a human to
# hand each one over is what left that column untriaged for two months.
#
# The widening is kept as narrow as it goes: one bucket, one column, one creator,
# and only card creation. Anything else on the same board still needs the
# operator. Corroboration is unaffected — the verifier re-fetches the card and
# confirms the claimed creator really filed it.
class BasecampAgentConnector::Basecamp::WatchedColumn
  SEPARATOR = ":"

  SPEC_FORMAT = "BUCKET:COLUMN[:CREATOR]"

  NUMERIC = /\A\d+\z/

  def self.parse(spec)
    bucket, column, creator = spec.to_s.split(SEPARATOR, 3)

    unless numeric?(bucket) && numeric?(column) && (creator.nil? || numeric?(creator))
      raise ArgumentError, "--watch-column wants #{SPEC_FORMAT} with numeric ids, got #{spec.inspect}"
    end

    new(bucket: bucket.to_i, column: column.to_i, creator: creator&.to_i)
  end

  def self.numeric?(value)
    value.to_s.match?(NUMERIC)
  end

  attr_reader :bucket, :column, :creator

  def initialize(bucket:, column:, creator: nil)
    @bucket = bucket
    @column = column
    @creator = creator
  end

  def matches?(event)
    event.card_created? &&
      event.bucket_id == bucket &&
      event.column_id == column &&
      created_by_allowed?(event)
  end

  def to_s
    [ bucket, column, creator ].compact.join(SEPARATOR)
  end

  private
    def created_by_allowed?(event)
      creator.nil? || event.creator_id == creator
    end
end
