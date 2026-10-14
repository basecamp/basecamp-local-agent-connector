require "test_helper"

class CommandRunnerTest < Minitest::Test
  def test_reads_utf_8_output_when_the_locale_is_ascii
    result = BasecampAgentConnector::CommandRunner.new.run(
      { "LC_ALL" => "C" }, Gem.ruby, "-e", 'STDOUT.write("{\"name\":\"Kim\xC3\xA9\"}")'
    )

    assert_equal Encoding::UTF_8, result.stdout.encoding
    assert_equal "Kimé", JSON.parse(result.stdout).fetch("name")
  end
end
