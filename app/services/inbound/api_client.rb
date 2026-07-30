require "httparty"

module Inbound
  # Thin wrapper over the Mailtrap Inbound API. The inbound endpoints are not
  # covered by the `mailtrap` gem (which handles Email Sending only), so they
  # are called directly here.
  #
  # The webhook payload carries only `inbox_id` and `message_id` — the sender,
  # subject and body have to be fetched with #fetch_message. Replies go back
  # through #reply, which threads them onto the original conversation for us.
  #
  # @see https://docs.mailtrap.io/developers/inbound/messages
  class ApiClient
    Error = Class.new(StandardError)

    BASE_URL        = "https://mailtrap.io/api/inbound/inboxes".freeze
    TIMEOUT_SECONDS = 10

    def initialize(api_token: nil)
      @api_token = api_token || ENV.fetch("MAILTRAP_API_TOKEN")
    end

    # Returns the full message, including `text_body` and `html_body`.
    def fetch_message(inbox_id:, message_id:)
      request(:get, "/#{inbox_id}/messages/#{message_id}")
    end

    # Replies on the original thread. Mailtrap sets In-Reply-To / References
    # itself, so the exchange stays one conversation in the prospect's mailbox
    # and in the Mailtrap dashboard.
    #
    # `from` is deliberately optional: Mailtrap-hosted inboxes always send from
    # their own address and reject the field. Only custom-domain inboxes accept
    # (and require) it.
    def reply(inbox_id:, message_id:, text:, html:, cc: [], from: nil, category: nil)
      body = { text: text, html: html }
      body[:from]     = { email: from, name: "Melissa" } if from.present?
      body[:cc]       = Array(cc).map { |address| { email: address } } if Array(cc).any?
      body[:category] = category if category.present?

      request(:post, "/#{inbox_id}/messages/#{message_id}/reply", body)
    end

    private

    def request(verb, path, body = nil)
      options = { headers: headers, timeout: TIMEOUT_SECONDS }
      options[:body] = body.to_json if body

      response = HTTParty.public_send(verb, "#{BASE_URL}#{path}", **options)
      raise Error, "#{verb.to_s.upcase} #{path} failed: HTTP #{response.code} #{response.body}" unless response.success?

      response.parsed_response
    end

    def headers
      {
        "Api-Token"    => @api_token,
        "Content-Type" => "application/json",
        "Accept"       => "application/json"
      }
    end
  end
end
