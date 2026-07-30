module Webhooks
  module Mailtrap
    # Receives Mailtrap Inbound webhooks.
    #
    # The request body is an envelope of events, not the email itself, so every
    # `inbound.message_received` event needs an API fetch before the lead
    # pipeline can run.
    #
    # Mailtrap retries any non-2xx response up to 10 times over 24 hours. That
    # is what we want for a genuine outage, but not for a single message we
    # cannot process, so per-message failures are logged and swallowed: one bad
    # message must not force redelivery of the whole batch.
    #
    # @see https://docs.mailtrap.io/inbound-email/webhooks
    class InboundController < ApplicationController
      skip_before_action :verify_authenticity_token

      def create
        raw_body  = request.raw_post
        signature = request.headers[Inbound::SignatureVerifier::HEADER_NAME].to_s

        unless Inbound::SignatureVerifier.new(raw_body, signature).valid?
          Rails.logger.warn("[MailtrapInbound] rejected — invalid signature")
          return head :bad_request
        end

        events = Inbound::EventParser.new(JSON.parse(raw_body)).message_received_events
        Rails.logger.info("[MailtrapInbound] #{events.size} message_received event(s)")

        events.each { |event| process_event(event) }

        head :ok
      rescue JSON::ParserError => e
        Rails.logger.error("[MailtrapInbound] invalid JSON: #{e.message}")
        head :bad_request
      end

      private

      # Deliberately not named `process`: ActionController::Metal#process is the
      # action-dispatch entry point, and overriding it stops the controller from
      # running its actions at all.
      def process_event(event)
        message    = api_client.fetch_message(inbox_id: event.inbox_id, message_id: event.message_id)
        normalized = Inbound::MessageNormalizer.new(message).call

        if Inbound::AutoResponderFilter.new(normalized).skip?
          Rails.logger.info("[MailtrapInbound] skipped #{event.message_id} — auto-responder / no-reply sender")
          return
        end

        Inbound::ProcessIncomingEmail.new(normalized).call
      rescue StandardError => e
        Rails.logger.error("[MailtrapInbound] message #{event.message_id} failed: #{e.class} — #{e.message}")
        Rails.logger.error(e.backtrace.first(10).join("\n"))
      end

      def api_client
        @api_client ||= Inbound::ApiClient.new
      end
    end
  end
end
