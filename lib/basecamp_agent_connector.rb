require "zeitwerk"

loader = Zeitwerk::Loader.for_gem
loader.inflector.inflect "cli" => "CLI", "basecamp_cli" => "BasecampCLI"
loader.setup

module BasecampAgentConnector
end
