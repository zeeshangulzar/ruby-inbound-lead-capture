# Processes a persisted InboundEvent off the queue. Fetches the full message
# from the Mailtrap Inbound API, normalizes it, applies the auto-responder
# filter, and hands off to ProcessIncomingEmail. Any exception is recorded on
# the event before being re-raised so ActiveJob's retry logic can back off.
#
# Idempotency:
#   - InboundEvent has unique indexes on event_id and message_id; the
#     controller inserts before enqueueing, so redelivered webhooks cannot
#     create two rows for the same event.
#   - The job short-circuits if the event has already been processed or
#     skipped — a duplicate enqueue is a no-op.
class ProcessInboundEventJob < ApplicationJob
  queue_as :default

  retry_on Inbound::ApiClient::Error,        wait: :polynomially_longer, attempts: 5
  retry_on Net::OpenTimeout, Net::ReadTimeout, wait: :polynomially_longer, attempts: 5

  discard_on ActiveJob::DeserializationError

  def perform(inbound_event_id)
    event = InboundEvent.find_by(id: inbound_event_id)
    return unless event

    return if event.status != InboundEvent::STATUS_QUEUED

    message    = api_client.fetch_message(inbox_id: event.inbox_id, message_id: event.message_id)
    normalized = Inbound::MessageNormalizer.new(message).call

    if Inbound::AutoResponderFilter.new(normalized).skip?
      Rails.logger.info("[ProcessInboundEventJob] skipped #{event.message_id} — auto-responder / no-reply sender")
      event.mark_skipped!("auto-responder or no-reply sender")
      return
    end

    Inbound::ProcessIncomingEmail.new(normalized).call
    event.mark_processed!
  rescue StandardError => e
    Rails.logger.error("[ProcessInboundEventJob] event #{inbound_event_id} failed: #{e.class} — #{e.message}")
    event&.mark_failed!(e)
    raise
  end

  private

  def api_client
    @api_client ||= Inbound::ApiClient.new
  end
end
