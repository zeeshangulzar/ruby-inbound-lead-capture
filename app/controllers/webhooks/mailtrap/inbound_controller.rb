module Webhooks
  module Mailtrap
    # Receives Mailtrap Inbound webhooks.
    #
    # The webhook body is an envelope of events — the sender, subject, and body
    # are not included and have to be fetched off the Inbound API. To keep the
    # HTTP response fast (and to survive slow AI / third-party calls without
    # tripping Mailtrap's retry policy), every valid event is persisted to
    # `inbound_events` and processed by ProcessInboundEventJob. The controller
    # only signs off with 200 once the events are safely on disk.
    #
    # Idempotency is enforced at the database via unique indexes on
    # `event_id` and `message_id`, so a Mailtrap redelivery (or an out-of-order
    # duplicate) collapses to a no-op instead of a second AI call and reply.
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

        payload = JSON.parse(raw_body)
        events  = Inbound::EventParser.new(payload).message_received_events
        Rails.logger.info("[MailtrapInbound] #{events.size} message_received event(s)")

        events.each { |event| persist_and_enqueue(event) }

        head :ok
      rescue JSON::ParserError => e
        Rails.logger.error("[MailtrapInbound] invalid JSON: #{e.message}")
        head :bad_request
      end

      private

      def persist_and_enqueue(event)
        event_id = event.event_id.presence || "msg-#{event.message_id}"

        record = InboundEvent.create!(
          event_id:   event_id,
          message_id: event.message_id,
          inbox_id:   event.inbox_id,
          status:     InboundEvent::STATUS_QUEUED,
          payload:    { "event_id" => event_id, "inbox_id" => event.inbox_id, "message_id" => event.message_id }
        )
        ProcessInboundEventJob.perform_later(record.id)
      rescue ActiveRecord::RecordNotUnique, ActiveRecord::RecordInvalid => e
        Rails.logger.info("[MailtrapInbound] duplicate event/message ignored (#{event.event_id} / #{event.message_id}): #{e.class}")
      end
    end
  end
end
