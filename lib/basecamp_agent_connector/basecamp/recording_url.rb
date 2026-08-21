require "uri"

# Turns a notification's browser URL into the API URL that `basecamp show` can
# actually fetch.
#
# Two things make this less trivial than a host swap. A notification about a
# comment points at the *card* the comment lives on and carries the comment id in
# a `#__recording_N` fragment, so the item to fetch is not the item in the path.
# And only typed endpoints resolve: `/buckets/B/comments/N.json` returns the
# comment, while the generic `/buckets/B/recordings/N.json` and a bare id both
# return nothing.
class BasecampAgentConnector::Basecamp::RecordingUrl
  API_HOST = "3.basecampapi.com"

  RECORDING_FRAGMENT = /\A__recording_(\d+)\z/

  BUCKET_PATH = %r{\A(?<prefix>/\d+/buckets/\d+)/}

  def self.from_app_url(app_url)
    new(app_url).to_s
  end

  def initialize(app_url)
    @uri = URI.parse(app_url.to_s)
  rescue URI::InvalidURIError
    @uri = nil
  end

  def to_s
    return nil if @uri.nil? || @uri.path.to_s.empty?

    URI::HTTPS.build(host: API_HOST, path: path).to_s
  end

  private
    def path
      if commented_recording_id && bucket_prefix
        comment_path
      else
        "#{@uri.path.chomp('/')}.json"
      end
    end

    def comment_path
      "#{bucket_prefix}/comments/#{commented_recording_id}.json"
    end

    def bucket_prefix
      @uri.path[BUCKET_PATH, :prefix]
    end

    def commented_recording_id
      @uri.fragment.to_s[RECORDING_FRAGMENT, 1]
    end
end
