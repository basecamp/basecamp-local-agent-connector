require "zeitwerk"

loader = Zeitwerk::Loader.for_gem
loader.inflector.inflect \
  "cli" => "CLI",
  "github" => "GitHub",
  "review_cli" => "ReviewCLI"
loader.setup

module BasecampAgentConnector
end
