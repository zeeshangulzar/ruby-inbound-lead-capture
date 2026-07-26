module Webhooks
  module Mailtrap
    class InboundController < ApplicationController
      skip_before_action :verify_authenticity_token

      def create
        raw_body  = request.raw_post
        signature = request.headers["X-MT-Signature"].to_s

        unless Inbound::SignatureVerifier.new(raw_body, signature).valid?
          Rails.logger.warn("[MailtrapInbound] rejected — invalid signature")
          return head :bad_request
        end

        payload = JSON.parse(raw_body)

        if Inbound::AutoResponderFilter.new(payload).skip?
          Rails.logger.info("[MailtrapInbound] skipped — auto-responder / no-reply sender")
          return head :ok
        end

        Inbound::ProcessIncomingEmail.new(payload).call
        head :ok
      rescue JSON::ParserError => e
        Rails.logger.error("[MailtrapInbound] invalid JSON: #{e.message}")
        head :bad_request
      rescue => e
        Rails.logger.error("[MailtrapInbound] failed: #{e.class} — #{e.message}")
        Rails.logger.error(e.backtrace.first(10).join("\n"))
        head :internal_server_error
      end
    end
  end
end
