module Inbound
  # Guards against reply loops: bounces, vacation auto-replies and no-reply
  # senders must never get a Melissa response.
  #
  # One caveat about the header checks. Mailtrap returns only a *selected*
  # subset of the original headers, so `Auto-Submitted` and `Precedence` are
  # often absent even when the sender set them — a real Gmail message arrived
  # here carrying just `mime-version` and `return-path`. The checks are kept
  # because they cost nothing when the headers are present, but the sender
  # patterns are what actually carry the weight.
  class AutoResponderFilter
    NO_REPLY_SENDER_PATTERNS = [
      /\Amailer-daemon@/i,
      /\Apostmaster@/i,
      /-noreply@/i,
      /\Ano-?reply@/i,
      /\Abounces?@/i,
      /\Adaemon@/i
    ].freeze

    def initialize(normalized)
      @normalized = normalized
    end

    def skip?
      return true if headers["auto-submitted"].to_s.match?(/\Aauto-/i)
      return true if headers["precedence"].to_s.match?(/\A(bulk|list|junk)\z/i)
      return true if headers["x-autoreply"].present? || headers["x-autorespond"].present?
      return true if sender_email.blank?
      return true if NO_REPLY_SENDER_PATTERNS.any? { |pattern| sender_email.match?(pattern) }

      false
    end

    private

    def sender_email
      @normalized.sender_email.to_s
    end

    def headers
      @normalized.headers || {}
    end
  end
end
