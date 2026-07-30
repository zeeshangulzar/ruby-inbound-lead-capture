module Inbound
  # Verifies the `Mailtrap-Signature` header on an inbound webhook.
  #
  # Mailtrap computes HMAC-SHA256(signing_secret, raw_request_body) and sends
  # the lowercase hex digest. The comparison is delegated to the `mailtrap`
  # gem's helper, which compares in constant time and returns false — rather
  # than raising — for anything malformed that could arrive over the wire.
  #
  # The raw body must be passed through untouched: parsing and re-serialising
  # the JSON can reorder keys and invalidate the signature.
  #
  # @see https://docs.mailtrap.io/inbound-email/webhooks
  class SignatureVerifier
    HEADER_NAME = "Mailtrap-Signature".freeze

    def initialize(raw_body, signature_header)
      @raw_body         = raw_body.to_s
      @signature_header = signature_header.to_s
    end

    def valid?
      Mailtrap::Webhooks.verify_signature(
        payload:        @raw_body,
        signature:      @signature_header,
        signing_secret: secret
      )
    end

    private

    def secret
      ENV["MAILTRAP_INBOUND_SECRET"].to_s
    end
  end
end
