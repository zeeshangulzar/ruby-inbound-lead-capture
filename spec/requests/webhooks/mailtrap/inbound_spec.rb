require "rails_helper"

RSpec.describe "POST /webhooks/mailtrap/inbound", type: :request do
  let(:secret) { "test-secret" }
  let(:payload) do
    {
      "thread_id" => "thread-xyz",
      "subject"   => "Interested in your consulting services",
      "from"      => { "email" => "prospect@acme.co", "name" => "Sam Prospect" },
      "text"      => "Hi — we're a 40-person team at acme.co with ~€5000 budget for 40 hours of training. Interested.",
      "headers"   => { "message-id" => "<msg-1@acme.co>" }
    }
  end
  let(:raw_body)  { payload.to_json }
  let(:signature) { OpenSSL::HMAC.hexdigest("SHA256", secret, raw_body) }

  before do
    ENV["MAILTRAP_INBOUND_SECRET"] = secret
    allow_any_instance_of(Inbound::ProcessIncomingEmail).to receive(:call)
  end

  after { ENV.delete("MAILTRAP_INBOUND_SECRET") }

  it "accepts a properly signed payload" do
    post "/webhooks/mailtrap/inbound", params: raw_body, headers: {
      "Content-Type"    => "application/json",
      "X-MT-Signature"  => signature
    }
    expect(response).to have_http_status(:ok)
  end

  it "rejects a tampered payload with 400" do
    post "/webhooks/mailtrap/inbound", params: raw_body, headers: {
      "Content-Type"    => "application/json",
      "X-MT-Signature"  => "not-the-right-signature"
    }
    expect(response).to have_http_status(:bad_request)
  end

  it "rejects a payload with a missing signature header" do
    post "/webhooks/mailtrap/inbound", params: raw_body, headers: { "Content-Type" => "application/json" }
    expect(response).to have_http_status(:bad_request)
  end

  it "returns 200 but skips processing for auto-responder emails" do
    auto = payload.merge("headers" => { "auto-submitted" => "auto-replied" })
    body = auto.to_json
    sig  = OpenSSL::HMAC.hexdigest("SHA256", secret, body)

    expect_any_instance_of(Inbound::ProcessIncomingEmail).not_to receive(:call)
    post "/webhooks/mailtrap/inbound", params: body, headers: {
      "Content-Type"   => "application/json",
      "X-MT-Signature" => sig
    }
    expect(response).to have_http_status(:ok)
  end

  it "returns 200 but skips processing for known no-reply senders" do
    auto = payload.merge("from" => { "email" => "mailer-daemon@example.com" })
    body = auto.to_json
    sig  = OpenSSL::HMAC.hexdigest("SHA256", secret, body)

    expect_any_instance_of(Inbound::ProcessIncomingEmail).not_to receive(:call)
    post "/webhooks/mailtrap/inbound", params: body, headers: {
      "Content-Type"   => "application/json",
      "X-MT-Signature" => sig
    }
    expect(response).to have_http_status(:ok)
  end
end
