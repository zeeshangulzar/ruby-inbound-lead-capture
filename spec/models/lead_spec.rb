require "rails_helper"

RSpec.describe Lead do
  subject(:lead) do
    described_class.new(
      thread_id:    "thread-abc",
      sender_email: "sam@example.com",
      status:       Lead::STATUS_IN_CONVERSATION
    )
  end

  describe "validations" do
    it { is_expected.to be_valid }

    it "requires a thread_id" do
      lead.thread_id = nil
      expect(lead).not_to be_valid
    end

    it "requires a sender_email" do
      lead.sender_email = nil
      expect(lead).not_to be_valid
    end

    it "enforces thread_id uniqueness" do
      lead.save!
      dup = described_class.new(thread_id: "thread-abc", sender_email: "other@example.com")
      expect(dup).not_to be_valid
    end

    it "rejects unknown status values" do
      lead.status = "gibberish"
      expect(lead).not_to be_valid
    end
  end

  describe "#missing_required_fields" do
    it "lists every required field when extracted_data is empty" do
      expect(lead.missing_required_fields).to match_array(Lead::REQUIRED_FIELDS)
    end

    it "returns only the blank ones" do
      lead.extracted_data = { "employees" => 42, "hours" => 20 }
      expect(lead.missing_required_fields).to match_array(%w[budget_eur website])
    end
  end

  describe "#ready_for_final_verdict?" do
    it "is true when all required fields are present" do
      lead.extracted_data = { "employees" => 40, "budget_eur" => 5000, "hours" => 40, "website" => "https://acme.co" }
      expect(lead).to be_ready_for_final_verdict
    end

    it "is true after the reply cap is hit" do
      lead.ai_reply_count = Lead::MAX_AI_REPLIES
      expect(lead).to be_ready_for_final_verdict
    end

    it "is false when data is missing and cap is not reached" do
      lead.ai_reply_count = 1
      expect(lead).not_to be_ready_for_final_verdict
    end
  end

  describe "#already_processed?" do
    it "is false before any message has been recorded" do
      expect(lead).not_to be_already_processed("msg-1")
    end

    it "is true for the message just processed" do
      lead.last_message_id = "msg-1"
      expect(lead).to be_already_processed("msg-1")
    end

    it "is false for a new message on the same thread" do
      lead.last_message_id = "msg-1"
      expect(lead).not_to be_already_processed("msg-2")
    end

    it "compares as strings, since ids arrive from JSON" do
      lead.last_message_id = "12345"
      expect(lead).to be_already_processed(12_345)
    end
  end

  describe "#reply_cap_reached?" do
    it "is false below the cap" do
      lead.ai_reply_count = Lead::MAX_AI_REPLIES - 1
      expect(lead).not_to be_reply_cap_reached
    end

    it "is true at the cap" do
      lead.ai_reply_count = Lead::MAX_AI_REPLIES
      expect(lead).to be_reply_cap_reached
    end
  end

  describe "#data_completeness" do
    it "is full when every required field is present" do
      lead.extracted_data = { "employees" => 40, "budget_eur" => 5000, "hours" => 40, "website" => "https://acme.co" }
      expect(lead.data_completeness).to eq("full")
    end

    it "is partial when one or two are missing" do
      lead.extracted_data = { "employees" => 40, "budget_eur" => 5000, "hours" => 40 }
      expect(lead.data_completeness).to eq("partial")

      lead.extracted_data = { "employees" => 40, "budget_eur" => 5000 }
      expect(lead.data_completeness).to eq("partial")
    end

    it "is minimal when three or more are missing" do
      lead.extracted_data = { "employees" => 40 }
      expect(lead.data_completeness).to eq("minimal")
    end

    # The spec requires the reply cap to report minimal, because at that point
    # we stopped asking and qualified on whatever was volunteered.
    it "is minimal once the reply cap is reached, even with only one field missing" do
      lead.extracted_data = { "employees" => 40, "budget_eur" => 5000, "hours" => 40 }
      lead.ai_reply_count = Lead::MAX_AI_REPLIES

      expect(lead.data_completeness).to eq("minimal")
    end

    it "is still full at the cap when nothing is missing" do
      lead.extracted_data = { "employees" => 40, "budget_eur" => 5000, "hours" => 40, "website" => "https://acme.co" }
      lead.ai_reply_count = Lead::MAX_AI_REPLIES

      expect(lead.data_completeness).to eq("full")
    end
  end

  describe "#tier / #score" do
    it "returns nil when verdict is absent" do
      expect(lead.tier).to be_nil
      expect(lead.score).to be_nil
    end

    it "reads from the verdict hash when present" do
      lead.verdict = { "tier" => "warm", "score" => 72 }
      expect(lead.tier).to eq("warm")
      expect(lead.score).to eq(72)
    end
  end
end
