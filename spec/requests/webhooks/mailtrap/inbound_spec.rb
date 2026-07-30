require "rails_helper"

RSpec.describe "POST /webhooks/mailtrap/inbound", type: :request do
  let(:body)       { webhook_body }
  let(:api_client) { instance_double(Inbound::ApiClient, fetch_message: inbound_message) }

  before do
    set_env("MAILTRAP_INBOUND_SECRET" => secret, "MAILTRAP_API_TOKEN" => api_token)
    allow(Inbound::ApiClient).to receive(:new).and_return(api_client)
    allow_any_instance_of(Inbound::ProcessIncomingEmail).to receive(:call)
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

    it "does not fetch anything when the signature fails" do
      expect(api_client).not_to receive(:fetch_message)
      post_webhook(body, { "Content-Type" => "application/json", "Mailtrap-Signature" => "deadbeef" })
    end

    it "rejects the header name the app used to read" do
      post_webhook(body, { "Content-Type" => "application/json", "X-MT-Signature" => signature_for(body) })
      expect(response).to have_http_status(:bad_request)
    end
  end

  describe "the events envelope" do
    it "fetches the message named by the event" do
      expect(api_client).to receive(:fetch_message).with(inbox_id: inbox_id, message_id: message_id)
      post_webhook
    end

    it "processes every message_received event in one delivery" do
      payload = webhook_body([message_received_event, message_received_event("message_id" => "second")])
      expect(api_client).to receive(:fetch_message).twice
      post_webhook(payload)

      expect(response).to have_http_status(:ok)
    end

    it "ignores other event types without fetching" do
      payload = webhook_body([message_received_event("event" => "inbound.message_deleted")])
      expect(api_client).not_to receive(:fetch_message)
      post_webhook(payload)

      expect(response).to have_http_status(:ok)
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

  describe "auto-responder filtering" do
    it "skips a no-reply sender without running the pipeline" do
      allow(api_client).to receive(:fetch_message).and_return(inbound_message("from" => "mailer-daemon@example.com"))
      expect_any_instance_of(Inbound::ProcessIncomingEmail).not_to receive(:call)
      post_webhook

      expect(response).to have_http_status(:ok)
    end

    it "skips an Auto-Submitted message when the header survives" do
      allow(api_client).to receive(:fetch_message)
        .and_return(inbound_message("headers" => { "auto-submitted" => "auto-replied" }))
      expect_any_instance_of(Inbound::ProcessIncomingEmail).not_to receive(:call)
      post_webhook
    end

    it "runs the pipeline for a genuine prospect" do
      expect_any_instance_of(Inbound::ProcessIncomingEmail).to receive(:call)
      post_webhook
    end
  end

  # Mailtrap retries any non-2xx up to 10 times over 24 hours, so a message we
  # can never process must not be answered with an error.
  describe "per-message failures" do
    it "still returns 200 when the message cannot be fetched" do
      allow(api_client).to receive(:fetch_message).and_raise(Inbound::ApiClient::Error, "HTTP 404")
      post_webhook

      expect(response).to have_http_status(:ok)
    end

    it "still returns 200 when processing raises" do
      allow_any_instance_of(Inbound::ProcessIncomingEmail).to receive(:call).and_raise(StandardError, "boom")
      post_webhook

      expect(response).to have_http_status(:ok)
    end

    it "processes the remaining messages after one fails" do
      payload    = webhook_body([message_received_event, message_received_event("message_id" => "second")])
      call_count = 0
      allow(api_client).to receive(:fetch_message) do
        call_count += 1
        raise Inbound::ApiClient::Error, "HTTP 500" if call_count == 1

        inbound_message
      end

      post_webhook(payload)
      expect(call_count).to eq(2)
      expect(response).to have_http_status(:ok)
    end
  end

  describe "end to end with the pipeline running" do
    before do
      allow_any_instance_of(Inbound::ProcessIncomingEmail).to receive(:call).and_call_original
      allow_any_instance_of(LeadQualifier).to receive(:call).and_return(qualification)
      allow_any_instance_of(MelissaMailer).to receive(:send_follow_up)
    end

    it "creates a lead from a real-shaped payload" do
      expect { post_webhook }.to change(Lead, :count).by(1)

      lead = Lead.last
      expect(lead.thread_id).to eq(thread_id)
      expect(lead.inbox_id).to eq(inbox_id)
      expect(lead.last_message_id).to eq(message_id)
      expect(lead.sender_email).to eq("sam@acme.co")
    end

    it "does not create a second lead when Mailtrap redelivers" do
      post_webhook
      expect { post_webhook }.not_to change(Lead, :count)
    end
  end
end
