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

    def handle(request, response, handler)
      if request.request_method == "POST"
        handler.call(Request.new(body: request.body, headers: request.header))
        response.status = 200
      else
        response.status = 404
      end
    end

    def log(message)
      @logger.puts message
    end
end
