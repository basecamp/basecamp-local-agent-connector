require "webrick"

class BasecampAgentConnector::Server
  Request = Data.define(:body, :headers) do
    def header(name)
      Array(headers[name.downcase]).first
    end
  end

  def initialize(port:, path:, handler:, logger: $stderr)
    @port = port
    @path = path
    @handler = handler
    @logger = logger
  end

  def start
    @webrick = build_webrick
    @webrick.mount_proc(@path) { |request, response| handle(request, response) }
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
        @handler.call(Request.new(body: request.body, headers: request.header))
        response.status = 200
      else
        response.status = 404
      end
    end

    def log(message)
      @logger.puts message
    end
end
