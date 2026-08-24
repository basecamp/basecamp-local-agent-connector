require "test_helper"
require "open3"
require "tempfile"

# The guard is a PreToolUse hook, not library code, so these tests drive it the
# way Claude Code does: a synthesized payload through psp-card-preview.py, which
# runs the hook itself. Re-implementing any check here would drift from the hook
# the way the old preview shim did.
class HumanCardGuardTest < Minitest::Test
  PREVIEW = File.expand_path("../hooks/psp-card-preview.py", __dir__)

  # Designated in hooks/psp-human-cards.json, so the guard resolves it from disk
  # and the tests make no Basecamp calls.
  CARD = "10229151367"

  EVIDENCE_PARAGRAPHS = <<~HTML
    <p>SessionPersistenceStore.save still calls valet.setObject on the main thread. It ran twice on 1.34.10, most recently on 21 August.</p>

    <p>Next step: your ruling on whether the residual gets its own card.</p>
  HTML

  def test_a_clean_comment_passes
    assert_equal "passes", guard(clean_body)
  end

  # --- Word cap --------------------------------------------------------------

  def test_refuses_a_comment_over_one_hundred_and_eighty_words
    report = guard(body_of_words(190))

    assert_match(/words, cap is 180/, report)
  end

  def test_allows_a_comment_under_one_hundred_and_eighty_words
    refute_match(/cap is 180/, guard(body_of_words(150)))
  end

  # --- Ornament --------------------------------------------------------------

  # Fernando, 2026-08-24, on "load-bearing": a word that says the thing matters
  # without saying what breaks. He had read it twice on a human card that day.
  def test_refuses_writerly_vocabulary_that_carries_no_fact
    report = guard(sentence_body("The follow-up is load-bearing."))

    assert_match(/ornament \('load-bearing'\)/, report)
  end

  # The terms this fleet uses with a technical meaning are the only word for the
  # thing, and denying them would deny the report that has to use them.
  def test_allows_fleet_vocabulary_that_only_looks_writerly
    %w[lens cadence].each do |term|
      report = guard(sentence_body("The #{term} is recorded on the pull request."))

      refute_match(/ornament/, report, "#{term} is fleet vocabulary and must stand")
    end
  end

  # "the ruling that said nothing would be built" is a relative clause. Only the
  # discourse marker opening a sentence is the fault.
  def test_that_said_is_only_a_fault_when_it_opens_a_sentence
    refute_match(/ornament/, guard(sentence_body("The ruling that said nothing would ship stands.")))
    assert_match(/ornament/, guard(sentence_body("It shipped. That said, the token still expires.")))
  end

  def test_leverage_is_a_fault_as_a_verb_and_not_as_a_noun
    refute_match(/ornament/, guard(sentence_body("The leverage it gives us is recorded.")))
    assert_match(/ornament/, guard(sentence_body("We leverage the cache that Sentry already holds.")))
  end

  # --- The empty sentence ----------------------------------------------------

  # Fernando, 2026-08-24, on a sentence he said he would not know how to
  # catalogue. Its subject stands in for the thing and the fact arrived in the
  # next sentence.
  def test_refuses_a_placeholder_subject_that_names_nothing
    [
      "One gap this makes reachable, which I left alone rather than widen a reviewed branch.",
      "Two corrections to what I put here earlier.",
      "The follow-up is load-bearing."
    ].each do |sentence|
      report = guard(sentence_body(sentence))

      assert_match(/empty sentence/, report, sentence)
      assert_includes report, sentence.chomp("."), "the offending sentence is quoted back"
    end
  end

  # The evidence half is what keeps the rule off sentences that merely start this
  # way. A placeholder subject that names its subject stands.
  def test_allows_a_placeholder_opener_that_names_something
    refute_match(/empty sentence/, guard(sentence_body("Two things turned up in HEY-DESKTOP-64Q.")))
    refute_match(/empty sentence/, guard(sentence_body("The follow-up is pull request 1648.")))
  end

  # Measured false positive: "My note that night predicted a different trigger"
  # is a fact about a specific note, and a possessive is what makes it one.
  def test_a_possessive_subject_is_not_a_placeholder
    report = guard(sentence_body("My note that night predicted a different trigger."))

    refute_match(/empty sentence/, report)
  end

  # The count in the stand-in is part of the stand-in, so writing it as a digit
  # must not buy the sentence its way out.
  def test_the_opening_count_does_not_count_as_evidence
    assert_match(/empty sentence/, guard(sentence_body("2 corrections to what I put here earlier.")))
  end

  private
    def guard(body)
      Tempfile.create([ "body", ".html" ]) do |file|
        file.write(body)
        file.flush
        stdout, _status = Open3.capture2("python3", PREVIEW, CARD, file.path)
        return stdout.strip
      end
    end

    def clean_body
      <<~HTML
        <p>The crash path is absent from every build carrying the fix. Sentry holds 354 events before it and none after, across ninety days.</p>

        #{EVIDENCE_PARAGRAPHS}
      HTML
    end

    def sentence_body(sentence)
      <<~HTML
        <p>#{sentence} Sentry holds 354 events before it and none after, across ninety days.</p>

        #{EVIDENCE_PARAGRAPHS}
      HTML
    end

    def body_of_words(count)
      opening = "Sentry holds 354 events before the fix and none after."
      filler = ([ "The report names the build, the person and the second it arrived." ] * 20).join(" ")
      words = (opening + " " + filler).split
      <<~HTML
        <p>#{words.first(count - 30).join(' ')}</p>

        #{EVIDENCE_PARAGRAPHS}
      HTML
    end
end
