require "test_helper"

class WebhookSignatureTest < Minitest::Test
  def test_accepts_a_correct_signature
    body = '{"hello":"world"}'

    assert BasecampAgentConnector::WebhookSignature.valid?(body: body, signature: sign(body, "s3cret"), secret: "s3cret")
  end

  def test_rejects_a_tampered_body
    refute BasecampAgentConnector::WebhookSignature.valid?(body: '{"hello":"evil"}', signature: sign('{"hello":"world"}', "s3cret"), secret: "s3cret")
  end

  def test_rejects_a_wrong_secret
    body = '{"hello":"world"}'

    refute BasecampAgentConnector::WebhookSignature.valid?(body: body, signature: sign(body, "other"), secret: "s3cret")
  end

  def test_rejects_a_missing_signature
    refute BasecampAgentConnector::WebhookSignature.valid?(body: "{}", signature: nil, secret: "s3cret")
  end
end
