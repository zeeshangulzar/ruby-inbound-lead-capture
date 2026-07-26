module Inbound
  class SignatureVerifier
    def initialize(raw_body, signature_header)
      @raw_body         = raw_body.to_s
      @signature_header = signature_header.to_s
    end

    def valid?
      return false if @signature_header.empty?
      return false if secret.blank?

      ActiveSupport::SecurityUtils.secure_compare(expected_signature, @signature_header)
    end

    private

    def expected_signature
      OpenSSL::HMAC.hexdigest("SHA256", secret, @raw_body)
    end

    def secret
      ENV["MAILTRAP_INBOUND_SECRET"].to_s
    end
  end
end
