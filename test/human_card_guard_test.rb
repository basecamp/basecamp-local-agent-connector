require "test_helper"
require "open3"
require "tempfile"

# The guard is a PreToolUse hook, not library code, so these tests drive it the
# way Claude Code does: a synthesized payload through psp-card-preview.py, which
# runs the hook itself. Re-implementing any check here would drift from the hook
# the way the old preview shim did.
class HumanCardGuardTest < Minitest::Test
  PREVIEW = File.expand_path("../hooks/psp-card-preview.py", __dir__)

  # Designated in the committed hooks/psp-human-cards.json, so the guard resolves
  # it from disk and the tests make no Basecamp calls. It has to be a card the
  # COMMITTED registry carries: keyed on one that only a working copy listed,
  # these tests would reach for the network on a clean checkout.
  CARD = "9956451955"

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

  # --- Effort accounting: build artifacts ------------------------------------

  # Fernando, 2026-08-24: "there's no need to state files changed, number of
  # tests passed." Both examples are his own, from comment 10234745406.
  def test_refuses_counts_of_our_own_work
    [ "It touches ten files rather than the eight I expected.",
      "Email is 1246 tests unchanged and Calendar 456, both succeeding.",
      "Two commits, description still empty." ].each do |sentence|
      assert_match(/effort accounting/, guard(sentence_body(sentence)), sentence)
    end
  end

  # The discriminator is the noun, never the number. These measure the world.
  def test_allows_counts_of_the_world
    [ "532 events and 111 users over ninety days.",
      "1.3.6 carries 654 users against 61 on 1.3.3.",
      "Five events and three users sit under 100 and under 50." ].each do |sentence|
      refute_match(/effort accounting/, guard(sentence_body(sentence)), sentence)
    end
  end

  # A commit count that is a DISTANCE measures the world too: how far a pin lags
  # its branch is true whether or not we ever touch it.
  def test_allows_a_commit_count_that_measures_distance
    refute_match(/effort accounting/, guard(sentence_body("The pin is seven commits behind its branch.")))
  end

  # A version must not supply the count. These cards carry dotted versions and
  # artifact nouns in the same breath, so the digits have to be kept apart.
  def test_a_version_number_is_not_a_count
    refute_match(/effort accounting/, guard(sentence_body("The 1.34.13 tests still pass on device.")))
  end

  # A plural noun between the count and the artifact means the artifact word is
  # doing another job -- here "file" is the verb.
  def test_a_plural_noun_between_the_count_and_the_artifact_blocks_it
    refute_match(/effort accounting/, guard(sentence_body("A quarter's 1,252 events file as one issue.")))
  end

  # He said mostly useless, not useless. The rule targets the count, so the
  # consequence standing beside an inventory is not collateral.
  def test_the_consequence_beside_a_count_keeps_its_place
    refute_match(/effort accounting/, guard(sentence_body("Missing those would have left Xcode pointed at 4.2.1.")))
    assert_match(/effort accounting/, guard(sentence_body("Two regenerated lockfiles carry the branch. Missing those would have left Xcode pointed at 4.2.1.")))
  end

  # `lines` is deliberately not an artifact noun: ten of its fourteen uses in the
  # corpus forecast work not yet done, which is the decision he is being asked
  # for rather than bookkeeping behind it.
  def test_a_line_count_is_left_alone
    refute_match(/effort accounting/, guard(sentence_body("The tag is three lines and hides the noise.")))
  end

  # A postmortem IS the accounting, and the existing exemption has to cover the
  # new nouns as well as the minutes.
  def test_a_postmortem_may_count_its_own_work
    body = <<~HTML
      <p>The postmortem for this effort reads as follows. It touches ten files and Email is 1246 tests unchanged.</p>

      #{EVIDENCE_PARAGRAPHS}
    HTML

    refute_match(/effort accounting/, guard(body))
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

  # --- The method preamble ---------------------------------------------------

  # Fernando, 2026-08-24: "I don't need meta-statements like 'Measuring the file
  # instead of the culprit:'. The rest of the sentence is useful enough."
  def test_refuses_a_clause_that_narrates_the_measuring
    report = guard(sentence_body("Measuring the file instead of the culprit: 353 events and 126 users, spread over 1.34.9 and 1.32.7."))

    assert_match(/method preamble/, report)
    assert_includes report, "Measuring the file instead of the culprit:"
  end

  # The handoff is a comma as often as a colon, and this one is his too.
  def test_refuses_the_comma_form_of_the_preamble
    report = guard(sentence_body("Queried directly, it is 356 events and 125 users over ninety days."))

    assert_match(/method preamble/, report)
    assert_includes report, "Queried directly,"
  end

  # A full sentence whose subject is a person and whose verb is the inspection is
  # a claim about verification, and it stands. It opens with the subject, not the
  # participle, which is the whole reason the rule can stay this narrow.
  def test_allows_a_person_saying_they_did_the_checking
    refute_match(/method preamble/, guard(sentence_body("I ran it myself rather than taking the agent's figure.")))
  end

  # The same claim punctuated the way anyone would actually write it. The
  # inspection verb now has a comma after it and content behind that, so only the
  # sentence-initial anchor keeps it out -- which is the narrowing the whole rule
  # rests on.
  def test_an_inspection_verb_mid_sentence_is_not_a_preamble
    refute_match(/method preamble/, guard(sentence_body("I ran it myself, rather than taking the agent's figure.")))
  end

  # The gerund is the subject of a general claim about the system, with no
  # handoff to a separate finding.
  def test_allows_a_gerund_subject_making_a_claim_about_the_system
    refute_match(/method preamble/, guard(sentence_body("Running the suite serially avoids the port collision.")))
  end

  # The same claim with a trailing subordinate clause. A comma alone must not
  # pull it in -- this is what the length bound and the finite-verb veto are for.
  def test_a_trailing_comma_does_not_make_a_claim_into_a_preamble
    refute_match(/method preamble/, guard(sentence_body("Running the suite serially avoids the port collision, which is why we serialize.")))
  end

  # Nothing is handed off, so there is no finding standing behind a preamble.
  def test_allows_a_participial_clause_that_is_the_whole_sentence
    refute_match(/method preamble/, guard(sentence_body("Counting the retries: twelve.")))
  end

  # Isolates the finite-verb veto. The clause is short enough to clear the length
  # bound, so only the verb inside it keeps this out -- a gerund subject with its
  # own predicate is a claim, not a preamble.
  def test_a_short_gerund_subject_with_its_own_verb_is_not_a_preamble
    refute_match(/method preamble/, guard(sentence_body("Testing this fails, which we already knew.")))
  end

  # Isolates the length bound on the comma form, which is deliberately shorter
  # than the colon's. A comma is the ambiguous handoff, so the rule under-reaches
  # there on purpose: this sentence IS a preamble and is knowingly let through,
  # because widening the comma to the colon's reach is what would start pulling
  # in gerund-subject claims. Measured cost over the corpus: nothing.
  def test_the_comma_form_stays_deliberately_narrow
    refute_match(/method preamble/, guard(sentence_body("Comparing the release list against the crash list, the fixed builds carry none of these.")))
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
