module Inbound
  class AutoResponderFilter
    NO_REPLY_SENDER_PATTERNS = [
      /\Amailer-daemon@/i,
      /\Apostmaster@/i,
      /-noreply@/i,
      /\Ano-?reply@/i
    ].freeze

    def initialize(payload)
      @payload = payload || {}
    end

    def skip?
      headers = normalize_headers(@payload["headers"])

      return true if headers["auto-submitted"].to_s.match?(/\Aauto-/i)
      return true if headers["precedence"].to_s.match?(/\A(bulk|list)\z/i)
      return true if NO_REPLY_SENDER_PATTERNS.any? { |re| sender_email.match?(re) }

      false
    end

    private

    def sender_email
      @payload.dig("from", "email").to_s
    end

    def normalize_headers(headers)
      case headers
      when Hash  then headers.transform_keys { |k| k.to_s.downcase }
      when Array then headers.each_with_object({}) { |h, acc| acc[h["name"].to_s.downcase] = h["value"] }
      else            {}
      end
    end
  end
end
