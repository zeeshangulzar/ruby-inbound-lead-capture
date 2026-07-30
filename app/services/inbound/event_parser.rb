module Inbound
  # Pulls the `inbound.message_received` events out of a webhook payload.
  #
  # Mailtrap posts an envelope rather than the email itself — one request can
  # carry several events, and event types other than `inbound.message_received`
  # are ignored here:
  #
  #   {"events":[{"event":"inbound.message_received","event_id":"…",
  #               "timestamp":1785398058498,"inbox_id":695,
  #               "message_id":"1872125554587900000",
  #               "from":"Sam Prospect <sam@acme.co>"}]}
  #
  # @see https://docs.mailtrap.io/inbound-email/webhooks
  class EventParser
    MESSAGE_RECEIVED = "inbound.message_received".freeze

    Event = Struct.new(:inbox_id, :message_id, :event_id, keyword_init: true)

    def initialize(payload)
      @payload = payload || {}
    end

    def message_received_events
      Array(@payload["events"])
        .select { |event| event.is_a?(Hash) && event["event"] == MESSAGE_RECEIVED }
        .map    { |event| build(event) }
        .select { |event| event.inbox_id.present? && event.message_id.present? }
    end

    private

    def build(event)
      Event.new(
        inbox_id:   event["inbox_id"],
        message_id: event["message_id"].to_s,
        event_id:   event["event_id"].to_s
      )
    end
  end
end
