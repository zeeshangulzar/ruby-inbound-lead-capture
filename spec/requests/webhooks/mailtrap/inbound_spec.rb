require "rails_helper"

RSpec.describe "POST /webhooks/mailtrap/inbound", type: :request do
  let(:body) { webhook_body }

  before do
    set_env("MAILTRAP_INBOUND_SECRET" => secret, "MAILTRAP_API_TOKEN" => api_token)
  end

  def post_webhook(payload = body, headers = nil)
    post "/webhooks/mailtrap/inbound", params: payload, headers: headers || signed_headers(payload)
  end

  describe "signature verification" do
    it "accepts a payload signed with the shared secret" do
      post_webhook
      expect(response).to have_http_status(:ok)
    end

    it "rejects a tampered signature" do
      post_webhook(body, { "Content-Type" => "application/json", "Mailtrap-Signature" => "deadbeef" })
      expect(response).to have_http_status(:bad_request)
    end

    it "rejects a missing signature header" do
      post_webhook(body, { "Content-Type" => "application/json" })
      expect(response).to have_http_status(:bad_request)
    end

    it "rejects a signature valid for a different body" do
      signature = signature_for(webhook_body([message_received_event("message_id" => "other")]))
      post_webhook(body, { "Content-Type" => "application/json", "Mailtrap-Signature" => signature })
      expect(response).to have_http_status(:bad_request)
    end

    it "does not persist anything when the signature fails" do
      expect {
        post_webhook(body, { "Content-Type" => "application/json", "Mailtrap-Signature" => "deadbeef" })
      }.not_to change(InboundEvent, :count)
    end

    it "does not enqueue any job when the signature fails" do
      before_count = ActiveJob::Base.queue_adapter.enqueued_jobs.size
      post_webhook(body, { "Content-Type" => "application/json", "Mailtrap-Signature" => "deadbeef" })
      expect(ActiveJob::Base.queue_adapter.enqueued_jobs.size).to eq(before_count)
    end
  end

  describe "the events envelope" do
    it "persists an InboundEvent and enqueues a job per message_received event" do
      expect {
        post_webhook
      }.to change(InboundEvent, :count).by(1).and have_enqueued_job(ProcessInboundEventJob)

      event = InboundEvent.last
      expect(event.message_id).to eq(message_id)
      expect(event.inbox_id).to eq(inbox_id)
      expect(event.status).to eq(InboundEvent::STATUS_QUEUED)
    end

    it "returns 200 without waiting for the job to run" do
      post_webhook
      expect(response).to have_http_status(:ok)
    end

    it "processes every message_received event in one delivery" do
      payload = webhook_body([message_received_event, message_received_event("event_id" => "second-event", "message_id" => "second")])
      expect { post_webhook(payload) }.to change(InboundEvent, :count).by(2)
    end

    it "ignores other event types" do
      payload = webhook_body([message_received_event("event" => "inbound.message_deleted")])
      expect { post_webhook(payload) }.not_to change(InboundEvent, :count)
    end

    it "accepts an empty events array" do
      post_webhook(webhook_body([]))
      expect(response).to have_http_status(:ok)
    end

    it "returns 400 for a body that is not JSON" do
      post_webhook("not json", { "Content-Type" => "application/json",
                                 "Mailtrap-Signature" => signature_for("not json") })
      expect(response).to have_http_status(:bad_request)
    end
  end

  describe "idempotency" do
    it "does not create a second InboundEvent when Mailtrap redelivers the same event" do
      post_webhook
      expect { post_webhook }.not_to change(InboundEvent, :count)
    end

    it "does not create a second InboundEvent when the same message arrives under a different event_id" do
      post_webhook
      payload = webhook_body([message_received_event("event_id" => "different-event")])
      expect { post_webhook(payload) }.not_to change(InboundEvent, :count)
    end

    it "still returns 200 on a duplicate delivery" do
      post_webhook
      post_webhook
      expect(response).to have_http_status(:ok)
    end
  end
end
