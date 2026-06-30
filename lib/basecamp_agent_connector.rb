require "zeitwerk"

loader = Zeitwerk::Loader.for_gem
loader.inflector.inflect "github" => "GitHub"
loader.setup

module BasecampAgentConnector
end
