require "rails_helper"

RSpec.describe Inbound::ProcessIncomingEmail do
  let(:normalized) { normalized_message }
  let(:mailer) do
    instance_double(MelissaMailer,
                    send_follow_up: MelissaMailer::Result.new(status: :sent, error: nil))
  end

  before do
    allow(MelissaMailer).to receive(:new).and_return(mailer)
    allow_any_instance_of(LeadQualifier).to receive(:call).and_return(qualification)
    allow_any_instance_of(VerdictRouter).to receive(:call)
  end

  def process(message = normalized)
    described_class.new(message).call
  end

  describe "creating the lead" do
    it "keys the lead on the thread so a conversation stays one record" do
      expect { process }.to change(Lead, :count).by(1)
      expect(Lead.last.thread_id).to eq(thread_id)
    end

    it "stores what is needed to reply later" do
      process
      lead = Lead.last

      expect(lead.inbox_id).to eq(inbox_id)
      expect(lead.last_message_id).to eq(message_id)
      expect(lead.sender_email).to eq("sam@acme.co")
      expect(lead.sender_name).to eq("Sam Prospect")
      expect(lead.last_subject).to eq("Interested in your consulting services")
    end

    it "reuses the existing lead for a second message on the same thread" do
      process
      second = normalized_message("id" => "second-message", "subject" => "Re: following up")

      expect { described_class.new(second).call }.not_to change(Lead, :count)
      expect(Lead.last.last_message_id).to eq("second-message")
    end
  end

  describe "duplicate webhook delivery" do
    it "does not qualify or reply a second time" do
      process

      expect_any_instance_of(LeadQualifier).not_to receive(:call)
      expect(mailer).not_to receive(:send_follow_up)
      process
    end
  end

  describe "when fields are still missing" do
    it "asks for them and counts the reply on success" do
      expect(mailer).to receive(:send_follow_up).with(reply_paragraphs: kind_of(Array))
        .and_return(MelissaMailer::Result.new(status: :sent, error: nil))
      process

      lead = Lead.last
      expect(lead.ai_reply_count).to eq(1)
      expect(lead.last_reply_status).to eq(Lead::REPLY_STATUS_SENT)
      expect(lead.status).to eq(Lead::STATUS_IN_CONVERSATION)
    end

    it "does not increment the count when the reply fails" do
      allow(mailer).to receive(:send_follow_up).and_return(
        MelissaMailer::Result.new(status: :failed, error: "HTTP 500")
      )

      process
      lead = Lead.last

      expect(lead.ai_reply_count).to eq(0)
      expect(lead.last_reply_status).to eq(Lead::REPLY_STATUS_FAILED)
      expect(lead.last_reply_error).to eq("HTTP 500")
    end
  end

  describe "when the lead is ready" do
    before do
      allow_any_instance_of(LeadQualifier).to receive(:call)
        .and_return(qualification(extracted_data: complete_extracted_data))
    end

    it "routes to the verdict instead of asking another question" do
      expect_any_instance_of(VerdictRouter).to receive(:call)
      expect(mailer).not_to receive(:send_follow_up)
      process
    end

    it "passes the qualifier's reasoning to the router" do
      captured = nil
      allow(VerdictRouter).to receive(:new) do |args|
        captured = args
        instance_double(VerdictRouter, call: nil)
      end

      allow_any_instance_of(LeadQualifier).to receive(:call)
        .and_return(qualification(extracted_data: complete_extracted_data, reasoning: "Full data supplied."))

      process
      expect(captured[:prior_reasoning]).to eq("Full data supplied.")
    end
  end

  describe "hostile email" do
    before do
      allow_any_instance_of(LeadQualifier).to receive(:call)
        .and_return(qualification(hostile: true, reasoning: "Abusive content."))
    end

    it "red-flags the lead and stays silent" do
      expect(mailer).not_to receive(:send_follow_up)
      process

      lead = Lead.last
      expect(lead.status).to eq(Lead::STATUS_RED_FLAGGED)
      expect(lead.tier).to eq(Lead::TIER_RED_FLAG)
      expect(lead.verdict["reasoning"]).to eq("Abusive content.")
    end
  end

  describe "when the AI is unavailable" do
    before do
      allow_any_instance_of(LeadQualifier).to receive(:call).and_return(
        qualification(fallback: true, extracted_data: {},
                      reasoning: "Anthropic API unavailable — generic acknowledgement sent.")
      )
    end

    it "records the lead as cold" do
      process
      expect(Lead.last.tier).to eq(Lead::TIER_COLD)
    end

    it "still sends the generic acknowledgement and counts a successful send" do
      expect(mailer).to receive(:send_follow_up).and_return(
        MelissaMailer::Result.new(status: :sent, error: nil)
      )
      process
      expect(Lead.last.ai_reply_count).to eq(1)
    end

    it "stops replying once the reply cap is reached" do
      Lead.create!(thread_id: thread_id, sender_email: "sam@acme.co", ai_reply_count: Lead::MAX_AI_REPLIES,
                   inbox_id: inbox_id, last_message_id: "prior")
      expect(mailer).not_to receive(:send_follow_up)

      process
    end
  end

  describe "already-closed leads" do
    it "ignores further email once finalized" do
      process
      Lead.last.update!(status: Lead::STATUS_FINALIZED)

      expect_any_instance_of(LeadQualifier).not_to receive(:call)
      described_class.new(normalized_message("id" => "second")).call
    end

    it "ignores further email once red-flagged" do
      process
      Lead.last.update!(status: Lead::STATUS_RED_FLAGGED)

      expect_any_instance_of(LeadQualifier).not_to receive(:call)
      described_class.new(normalized_message("id" => "second")).call
    end
  end
end
