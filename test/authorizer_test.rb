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
    allowlist = authorizer(trust: :allowlist, emails: [ "marie@example.com", "sam@elsewhere.net" ])

    assert allowlist.authorizes?(mention_by(OPERATOR))
    assert allowlist.authorizes?(mention_by(COLLEAGUE))
    assert allowlist.authorizes?(mention_by(STRANGER))
    refute allowlist.authorizes?(mention_by("id" => 500, "email_address" => "other@example.com"))
  end

  def test_allowlist_matches_emails_case_insensitively
    allowlist = authorizer(trust: :allowlist, emails: [ "Marie@Example.com" ])

    assert allowlist.authorizes?(mention_by(COLLEAGUE))
  end

  def test_allowlist_never_authorizes_the_agent_even_when_listed
    allowlist = authorizer(trust: :allowlist, emails: [ "clawdito@example.com" ])

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
    # matched by Person id even when the email claims someone else
    refute project.authorizes?(mention_by("id" => 200, "email_address" => "someone@example.com"))
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
    allowlist = authorizer(trust: :allowlist, emails: [ "marie@example.com" ])

    assert allowlist.authorizes?(assignment_by(OPERATOR))
    refute allowlist.authorizes?(assignment_by(COLLEAGUE))
  end

  def test_assignments_open_to_authorized_authors_only_by_explicit_opt_in
    allowlist = authorizer(trust: :allowlist, emails: [ "marie@example.com" ], allow_assignments: true)

    assert allowlist.authorizes?(assignment_by(COLLEAGUE))
    refute allowlist.authorizes?(assignment_by(STRANGER))
    refute allowlist.authorizes?(assignment_by(AGENT))
  end

  def test_describes_the_active_trust_configuration
    assert_equal "operator only (operator@example.com); assignments: operator only", authorizer.description
    assert_equal "allowlist — operator (operator@example.com) + marie@example.com; assignments: operator only",
      authorizer(trust: :allowlist, emails: [ "marie@example.com" ]).description
    assert_equal "any corroborated project member (clients excluded); assignments: operator only",
      authorizer(trust: :project).description
    assert_equal "any @37signals.com author; assignments: any authorized author",
      authorizer(trust: :domain, allow_assignments: true).description
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
end
