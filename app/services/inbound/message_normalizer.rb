require "mail"

module Inbound
  # Extracts the small set of fields the app cares about from a message fetched
  # off the Inbound API. Nothing beyond this shape is persisted — raw email
  # content is used at qualification time and then discarded.
  #
  # `from` arrives as a single RFC-822 string ("Sam Prospect <sam@acme.co>"),
  # not as a structured address, so the display name and mailbox are split out
  # here.
  #
  # @see https://docs.mailtrap.io/developers/inbound/messages
  class MessageNormalizer
    Result = Struct.new(
      :inbox_id, :message_id, :thread_id,
      :sender_email, :sender_name, :subject, :body_text, :headers,
      keyword_init: true
    )

    def initialize(message)
      @message = message || {}
    end

    def call
      email, name = split_from(@message["from"])

      Result.new(
        inbox_id:     @message["inbox_id"],
        message_id:   @message["id"].to_s,
        thread_id:    thread_id,
        sender_email: email,
        sender_name:  name,
        subject:      @message["subject"].to_s,
        body_text:    body_text,
        headers:      normalize_headers(@message["headers"])
      )
    end

    private

    # Threads group the conversation. Fall back to the RFC Message-ID, then to
    # the Mailtrap message id, so a lead is never keyed on nil.
    def thread_id
      @message["thread_id"].presence ||
        @message["rfc_message_id"].presence ||
        @message["id"].to_s
    end

    def body_text
      text = @message["text_body"].to_s
      return text if text.present?

      html = @message["html_body"].to_s
      html.present? ? ActionController::Base.helpers.strip_tags(html).squish : ""
    end

    # Mail::Address handles the quoting and comment forms that show up in real
    # headers; a malformed value falls back to a plain angle-bracket scan.
    def split_from(raw)
      value = raw.to_s.strip
      return ["", ""] if value.empty?

      parsed = Mail::Address.new(value)
      [parsed.address.to_s.downcase, parsed.display_name.to_s]
    rescue StandardError
      [value[/<([^>]+)>/, 1].to_s.downcase.presence || value.downcase, value[/\A([^<]+)</, 1].to_s.strip]
    end

    def normalize_headers(headers)
      case headers
      when Hash  then headers.transform_keys { |key| key.to_s.downcase }
      when Array then headers.each_with_object({}) { |h, acc| acc[h["name"].to_s.downcase] = h["value"] }
      else            {}
      end
    end
  end
end
