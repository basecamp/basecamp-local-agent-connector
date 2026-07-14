require_relative "lib/basecamp_agent_connector/version"

Gem::Specification.new do |spec|
  spec.name = "basecamp_agent_connector"
  spec.version = BasecampAgentConnector::VERSION
  spec.authors = [ "Jorge Manrubia" ]
  spec.summary = "Bridge Basecamp webhooks to local Claude Code agents"
  spec.description = "Exposes a local webhook endpoint via Tailscale Funnel, registers it as a " \
    "Basecamp webhook, and emits trusted, self-authored, trigger-matched events for a local agent to act on."
  spec.homepage = "https://github.com/basecamp/basecamp-local-agent-connector"
  spec.license = "MIT"
  spec.required_ruby_version = ">= 3.4"

  spec.files = Dir["lib/**/*.rb", "bin/*", "skills/**/*", "README.md", "docs/**/*"]
  spec.bindir = "bin"
  spec.executables = [ "connect" ]
  spec.require_paths = [ "lib" ]

  spec.add_dependency "webrick", "~> 1.9"
  spec.add_dependency "zeitwerk", "~> 2.6"
  spec.add_dependency "faye-websocket", "~> 0.11"
end
