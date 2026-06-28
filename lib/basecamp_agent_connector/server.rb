require "webrick"
require "json"

class BasecampAgentConnector::Server
  def initialize(port:, secret:, handler:, logger: $stderr)
    @port = port
    @secret = secret
    @handler = handler
    @logger = logger
  end

  def start
    @webrick = build_webrick
    @webrick.mount_proc("/hook/#{@secret}") { |request, response| handle(request, response) }
    @webrick.start
  end

  def stop
    @webrick&.shutdown
  end

  private
    def build_webrick
      WEBrick::HTTPServer.new \
        Port: @port,
        BindAddress: "127.0.0.1",
        Logger: WEBrick::Log.new(File::NULL),
        AccessLog: []
    end

    def handle(request, response)
      if request.request_method == "POST"
        accept(request.body)
        response.status = 200
      else
        response.status = 404
      end
    end

    def accept(body)
      @handler.call(JSON.parse(body))
    rescue JSON::ParserError => error
      log "ignored malformed payload: #{error.message}"
    end

    def log(message)
      @logger.puts message
    end
end
