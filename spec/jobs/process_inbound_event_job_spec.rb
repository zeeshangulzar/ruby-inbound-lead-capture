require "rails_helper"

RSpec.describe ProcessInboundEventJob do
  let(:event) do
    InboundEvent.create!(event_id: "evt-1", message_id: message_id, inbox_id: inbox_id)
  end

  let(:api_client) { instance_double(Inbound::ApiClient, fetch_message: inbound_message) }

  before do
    allow(Inbound::ApiClient).to receive(:new).and_return(api_client)
    allow_any_instance_of(Inbound::ProcessIncomingEmail).to receive(:call)
  end

  it "fetches the message named on the event" do
    expect(api_client).to receive(:fetch_message).with(inbox_id: inbox_id, message_id: message_id)
    described_class.perform_now(event.id)
  end

  it "marks the event processed on success" do
    described_class.perform_now(event.id)
    expect(event.reload.status).to eq(InboundEvent::STATUS_PROCESSED)
    expect(event.processed_at).not_to be_nil
  end

  it "runs the pipeline for a genuine prospect" do
    expect_any_instance_of(Inbound::ProcessIncomingEmail).to receive(:call)
    described_class.perform_now(event.id)
  end

  it "marks the event skipped for an auto-responder without calling the pipeline" do
    allow(api_client).to receive(:fetch_message).and_return(inbound_message("from" => "mailer-daemon@example.com"))
    expect_any_instance_of(Inbound::ProcessIncomingEmail).not_to receive(:call)

    described_class.perform_now(event.id)
    expect(event.reload.status).to eq(InboundEvent::STATUS_SKIPPED)
  end

  it "records the failure on the event when the fetch raises" do
    allow(api_client).to receive(:fetch_message).and_raise(Inbound::ApiClient::Error, "HTTP 500")

    # retry_on swallows the raise and enqueues a retry; the failure is still
    # recorded on the event before the retry is scheduled.
    described_class.perform_now(event.id)

    expect(event.reload.status).to eq(InboundEvent::STATUS_FAILED)
    expect(event.last_error).to include("HTTP 500")
  end

  it "is idempotent — a second run on a processed event is a no-op" do
    described_class.perform_now(event.id)
    expect_any_instance_of(Inbound::ProcessIncomingEmail).not_to receive(:call)

    described_class.perform_now(event.id)
  end

  it "silently ignores a missing event id" do
    expect { described_class.perform_now(999_999) }.not_to raise_error
  end
end
