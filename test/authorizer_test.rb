require "test_helper"

class AuthorizerTest < Minitest::Test
  OPERATOR = { "id" => 100, "name" => "Operator", "email_address" => "operator@example.com", "client" => false }
  COLLEAGUE = { "id" => 300, "name" => "Marie", "email_address" => "marie@example.com", "client" => false }
  STRANGER = { "id" => 400, "name" => "Sam", "email_address" => "sam@elsewhere.net", "client" => false }
  AGENT = { "id" => 200, "name" => "Clawdito", "email_address" => "clawdito@example.com", "client" => false }

  def test_operator_mode_authorizes_only_the_operator
    assert authorizer.authorizes?(mention_by(OPERATOR))
    refute authorizer.authorizes?(mention_by(COLLEAGUE))
    refute authorizer.authorizes?(mention_by(AGENT))
  end

  def test_allowlist_authorizes_the_operator_and_each_allowed_email
    allowlist = authorizer(trust: :allowlist, operators: [ "marie@example.com", "sam@elsewhere.net" ])

    assert allowlist.authorizes?(mention_by(OPERATOR))
    assert allowlist.authorizes?(mention_by(COLLEAGUE))
    assert allowlist.authorizes?(mention_by(STRANGER))
    refute allowlist.authorizes?(mention_by("id" => 500, "email_address" => "other@example.com"))
  end

  def test_allowlist_matches_emails_case_insensitively
    allowlist = authorizer(trust: :allowlist, operators: [ "Marie@Example.com" ])

    assert allowlist.authorizes?(mention_by(COLLEAGUE))
  end

  def test_allowlist_never_authorizes_the_agent_even_when_listed
    allowlist = authorizer(trust: :allowlist, operators: [ "clawdito@example.com" ])

    refute allowlist.authorizes?(mention_by(AGENT))
  end

  def test_project_mode_authorizes_any_corroborated_author
    project = authorizer(trust: :project)

    assert project.authorizes?(mention_by(COLLEAGUE))
    assert project.authorizes?(mention_by(STRANGER))
  end

  def test_project_mode_refuses_client_users_and_missing_creators
    project = authorizer(trust: :project)

    refute project.authorizes?(mention_by(COLLEAGUE.merge("client" => true)))
    refute project.authorizes?(mention_by({}))
  end

  def test_project_mode_fails_closed_when_the_client_flag_is_absent
    project = authorizer(trust: :project)

    # No leaked secret path needed: if the corroborated recording omits the
    # client flag, the author is untrusted rather than assumed an employee.
    refute project.authorizes?(mention_by("id" => 300, "email_address" => "marie@example.com"))
    refute project.authorizes?(mention_by(COLLEAGUE.merge("client" => nil)))
    refute project.authorizes?(mention_by(COLLEAGUE.merge("client" => "false")))
  end

  def test_project_mode_never_authorizes_the_agent
    project = authorizer(trust: :project)

    refute project.authorizes?(mention_by(AGENT))
    # matched by Person id even when the email claims someone else; client=>false
    # so it is the self-exclusion guard, not the fail-closed client check, that drops it
    refute project.authorizes?(mention_by("id" => 200, "email_address" => "someone@example.com", "client" => false))
  end

  def test_domain_mode_authorizes_matching_domains_only
    domain = authorizer(trust: :domain, domains: [ "example.com" ])

    assert domain.authorizes?(mention_by(COLLEAGUE))
    assert domain.authorizes?(mention_by(COLLEAGUE.merge("email_address" => "Marie@EXAMPLE.COM")))
    refute domain.authorizes?(mention_by(STRANGER))
    refute domain.authorizes?(mention_by(COLLEAGUE.merge("email_address" => nil)))
  end

  def test_domain_mode_matches_the_domain_part_exactly
    domain = authorizer(trust: :domain, domains: [ "example.com" ])

    refute domain.authorizes?(mention_by("id" => 500, "email_address" => "sam@notexample.com"))
    refute domain.authorizes?(mention_by("id" => 500, "email_address" => "sam@mail.example.com"))
  end

  def test_domain_mode_tolerates_a_leading_at_sign_in_the_configured_domain
    domain = authorizer(trust: :domain, domains: [ "@example.com" ])

    assert domain.authorizes?(mention_by(COLLEAGUE))
  end

  def test_domain_mode_never_authorizes_the_agent_on_a_shared_domain
    domain = authorizer(trust: :domain, domains: [ "example.com" ])

    refute domain.authorizes?(mention_by(AGENT))
  end

  def test_domain_mode_defaults_to_37signals
    domain = authorizer(trust: :domain)

    assert domain.authorizes?(mention_by("id" => 500, "email_address" => "andrea@37signals.com"))
    refute domain.authorizes?(mention_by(COLLEAGUE))
  end

  def test_assignments_stay_operator_only_in_broadened_modes
    allowlist = authorizer(trust: :allowlist, operators: [ "marie@example.com" ])

    assert allowlist.authorizes?(assignment_by(OPERATOR))
    refute allowlist.authorizes?(assignment_by(COLLEAGUE))
  end

  def test_assignments_open_to_named_operators_only_by_explicit_opt_in
    allowlist = authorizer(trust: :allowlist, operators: [ "marie@example.com" ], allow_assignments: true)

    assert allowlist.authorizes?(assignment_by(COLLEAGUE))
    refute allowlist.authorizes?(assignment_by(STRANGER))
    refute allowlist.authorizes?(assignment_by(AGENT))
  end

  def test_the_operator_and_named_authors_are_operators
    allowlist = authorizer(trust: :allowlist, operators: [ "marie@example.com" ])

    assert_equal :operator, allowlist.role(mention_by(OPERATOR))
    assert_equal :operator, allowlist.role(mention_by(COLLEAGUE))
    assert_nil allowlist.role(mention_by(STRANGER))
  end

  def test_domain_and_project_authors_are_participants
    assert_equal :participant, authorizer(trust: :domain, domains: [ "example.com" ]).role(mention_by(COLLEAGUE))
    assert_equal :participant, authorizer(trust: :project).role(mention_by(STRANGER))
    assert_equal :operator, authorizer(trust: :project).role(mention_by(OPERATOR))
  end

  def test_a_named_operator_stays_an_operator_inside_the_participant_set
    domain = authorizer(trust: :domain, operators: [ "marie@example.com" ], domains: [ "example.com" ])

    assert_equal :operator, domain.role(mention_by(COLLEAGUE))
    assert_equal :participant, domain.role(mention_by("id" => 500, "email_address" => "ana@example.com"))
    assert_nil domain.role(mention_by(STRANGER))
  end

  def test_participants_never_trigger_by_assignment_or_boost
    project = authorizer(trust: :project, allow_assignments: true)

    refute project.authorizes?(assignment_by(COLLEAGUE))
    refute project.authorizes?(boost_by(COLLEAGUE))
    assert project.authorizes?(assignment_by(OPERATOR))
    assert project.authorizes?(boost_by(OPERATOR))
  end

  def test_named_operators_boost_but_assign_only_by_opt_in
    allowlist = authorizer(trust: :domain, operators: [ "marie@example.com" ], domains: [ "example.com" ])

    assert_equal :operator, allowlist.role(boost_by(COLLEAGUE))
    assert_nil allowlist.role(assignment_by(COLLEAGUE))
    assert_equal :operator, authorizer(trust: :allowlist, operators: [ "marie@example.com" ], allow_assignments: true).role(assignment_by(COLLEAGUE))
  end

  def test_says_when_it_refuses_a_participants_directive
    domain = authorizer(trust: :domain, operators: [ "marie@example.com" ], domains: [ "example.com" ])
    participant = { "id" => 500, "email_address" => "ana@example.com" }

    assert domain.refuses_participant_directive?(assignment_by(participant))
    assert domain.refuses_participant_directive?(boost_by(participant))
    refute domain.refuses_participant_directive?(mention_by(participant))
    refute domain.refuses_participant_directive?(BasecampAgentConnector::Basecamp::Event.from_payload(
      assignment_payload("creator" => participant, "details" => { "added_person_ids" => [ 999 ] }))),
      "an assignment of someone else is not aimed at the agent, even on a card that mentions it"
    refute domain.refuses_participant_directive?(assignment_by(COLLEAGUE)), "a named operator's refused assignment is not a participant's"
    refute domain.refuses_participant_directive?(assignment_by(STRANGER))
    refute domain.refuses_participant_directive?(assignment_by(AGENT))
  end

  def test_describes_the_active_trust_configuration
    assert_equal "operators: operator@example.com; participants: none; assignments: operator only", authorizer.description
    assert_equal "operators: operator@example.com, marie@example.com; participants: none; assignments: operator only",
      authorizer(trust: :allowlist, operators: [ "marie@example.com" ]).description
    assert_equal "operators: operator@example.com; participants: any corroborated project member (clients excluded); assignments: operator only",
      authorizer(trust: :project).description
    assert_equal "operators: operator@example.com, rob@37signals.com; participants: any @37signals.com author; assignments: operators",
      authorizer(trust: :domain, operators: [ "rob@37signals.com" ], allow_assignments: true).description
  end

  def test_refuses_an_unknown_trust_mode
    assert_raises ArgumentError do
      authorizer(trust: :everyone)
    end
  end

  private
    def mention_by(creator)
      BasecampAgentConnector::Basecamp::Event.from_payload(sample_payload("creator" => creator))
    end

    def assignment_by(creator)
      BasecampAgentConnector::Basecamp::Event.from_payload(assignment_payload("creator" => creator))
    end

    def boost_by(booster)
      BasecampAgentConnector::Basecamp::Event.from_payload(boost_payload(received_boost("booster" => booster)))
    end
end
