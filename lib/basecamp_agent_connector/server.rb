require "webrick"

class BasecampAgentConnector::Server
  Request = Data.define(:body, :headers) do
    def header(name)
      Array(headers[name.downcase]).first
    end
  end

  def initialize(port:, routes:, logger: $stderr)
    @port = port
    @routes = routes
    @logger = logger
  end

  def start
    @webrick = build_webrick
    @routes.each do |path, handler|
      @webrick.mount_proc(path) { |request, response| handle(request, response, handler) }
    end
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

    # A handler answers with the HTTP status to send, or nil for 200. The
    # Basecamp route uses that to ask for a redelivery (503) when it could
    # not reach a verdict; a handler that defers its work returns nil.
    def handle(request, response, handler)
      if request.request_method == "POST"
        response.status = handler.call(Request.new(body: request.body, headers: request.header)) || 200
      else
        response.status = 404
      end
    end

    def log(message)
      @logger.puts message
    end
end
