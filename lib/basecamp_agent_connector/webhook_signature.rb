require "openssl"

# Verifies the HMAC-SHA256 signature GitHub sends on every webhook delivery
# (`X-Hub-Signature-256: sha256=<hex>`), computed over the raw request body with
# the shared secret registered on the hook. Basecamp webhooks carry no signature
# — this is why the GitHub side can verify authenticity cryptographically.
class BasecampAgentConnector::WebhookSignature
  PREFIX = "sha256="

  def self.valid?(body:, signature:, secret:)
    return false if signature.nil? || secret.nil?

    expected = PREFIX + OpenSSL::HMAC.hexdigest("SHA256", secret, body)
    secure_compare(expected, signature)
  end

  def self.secure_compare(expected, given)
    expected.bytesize == given.bytesize && OpenSSL.fixed_length_secure_compare(expected, given)
  end
  private_class_method :secure_compare
end
