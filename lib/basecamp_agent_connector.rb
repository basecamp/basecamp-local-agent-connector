require "zeitwerk"

loader = Zeitwerk::Loader.for_gem
loader.inflector.inflect \
  "cli" => "CLI",
  "basecamp_cli" => "BasecampCLI",
  "github_cli" => "GithubCLI",
  "review_cli" => "ReviewCLI"
loader.setup

module BasecampAgentConnector
end
