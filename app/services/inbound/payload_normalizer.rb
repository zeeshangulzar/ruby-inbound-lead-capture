module Inbound
  # Extracts the small set of fields the app cares about from the Mailtrap
  # Inbound webhook payload. Nothing beyond this shape is persisted — raw
  # email content is used at qualification time and then discarded.
  class PayloadNormalizer
    Result = Struct.new(:thread_id, :sender_email, :sender_name, :subject, :body_text, keyword_init: true)

    def initialize(payload)
      @payload = payload || {}
    end

    def call
      Result.new(
        thread_id:    thread_id,
        sender_email: @payload.dig("from", "email").to_s.downcase,
        sender_name:  @payload.dig("from", "name").to_s,
        subject:      @payload["subject"].to_s,
        body_text:    body_text
      )
    end

    private

    def thread_id
      @payload["thread_id"].presence ||
        @payload.dig("headers", "message-id").presence ||
        SecureRandom.uuid
    end

    def body_text
      text = @payload["text"].to_s
      return text if text.present?

      html = @payload["html"].to_s
      html.present? ? ActionController::Base.helpers.strip_tags(html) : ""
    end
  end
end
