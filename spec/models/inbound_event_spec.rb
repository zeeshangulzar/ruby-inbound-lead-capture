require "rails_helper"

RSpec.describe InboundEvent do
  let(:event) do
    described_class.create!(event_id: "evt-1", message_id: "msg-1", inbox_id: 100)
  end

  describe "validations" do
    it "requires an event_id" do
      record = described_class.new(message_id: "msg-2")
      expect(record).not_to be_valid
      expect(record.errors[:event_id]).to be_present
    end

    it "requires a message_id" do
      record = described_class.new(event_id: "evt-2")
      expect(record).not_to be_valid
      expect(record.errors[:message_id]).to be_present
    end

    it "rejects an unknown status" do
      record = described_class.new(event_id: "evt-2", message_id: "msg-2", status: "bogus")
      expect(record).not_to be_valid
    end
  end

  describe "uniqueness" do
    it "prevents two rows with the same event_id" do
      described_class.create!(event_id: "evt-x", message_id: "msg-a")
      duplicate = described_class.new(event_id: "evt-x", message_id: "msg-b")

      expect(duplicate).not_to be_valid
      expect(duplicate.errors[:event_id]).to be_present
    end

    it "prevents two rows with the same message_id" do
      described_class.create!(event_id: "evt-a", message_id: "msg-x")
      duplicate = described_class.new(event_id: "evt-b", message_id: "msg-x")

      expect(duplicate).not_to be_valid
      expect(duplicate.errors[:message_id]).to be_present
    end

    it "raises RecordNotUnique when the model-level check is bypassed" do
      described_class.create!(event_id: "evt-x", message_id: "msg-a")

      expect {
        described_class.connection.execute(
          "INSERT INTO inbound_events (event_id, message_id, status, created_at, updated_at) " \
          "VALUES ('evt-x', 'msg-b', 'queued', datetime('now'), datetime('now'))"
        )
      }.to raise_error(ActiveRecord::RecordNotUnique)
    end
  end

  describe "state transitions" do
    it "marks processed with a timestamp" do
      event.mark_processed!
      expect(event.status).to eq(described_class::STATUS_PROCESSED)
      expect(event.processed_at).not_to be_nil
    end

    it "marks skipped with a reason" do
      event.mark_skipped!("auto-responder")
      expect(event.status).to eq(described_class::STATUS_SKIPPED)
      expect(event.last_error).to eq("auto-responder")
    end

    it "marks failed with a class:message summary" do
      error = StandardError.new("boom")
      event.mark_failed!(error)

      expect(event.status).to eq(described_class::STATUS_FAILED)
      expect(event.last_error).to include("StandardError")
      expect(event.last_error).to include("boom")
    end
  end
end
