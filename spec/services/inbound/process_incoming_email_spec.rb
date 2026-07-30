require "rails_helper"

RSpec.describe Inbound::ProcessIncomingEmail do
  let(:normalized) { normalized_message }
  let(:mailer)     { instance_double(MelissaMailer, send_follow_up: nil) }

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
      expect(Lead.last.last_subject).to eq("Re: following up")
    end

    it "keeps the previous subject when a reply arrives with none" do
      process
      described_class.new(normalized_message("id" => "second", "subject" => "")).call

      expect(Lead.last.last_subject).to eq("Interested in your consulting services")
    end
  end

  describe "duplicate webhook delivery" do
    it "does not qualify or reply a second time" do
      process

      expect_any_instance_of(LeadQualifier).not_to receive(:call)
      expect(mailer).not_to receive(:send_follow_up)
      process
    end

    it "leaves the reply count untouched" do
      process
      expect { process }.not_to change { Lead.last.reload.ai_reply_count }
    end
  end

  describe "when fields are still missing" do
    it "asks for them and counts the reply" do
      expect(mailer).to receive(:send_follow_up)
      process

      expect(Lead.last.ai_reply_count).to eq(1)
      expect(Lead.last.status).to eq(Lead::STATUS_IN_CONVERSATION)
    end

    it "merges newly supplied fields over the rounds" do
      allow_any_instance_of(LeadQualifier).to receive(:call)
        .and_return(qualification(extracted_data: { "employees" => 40 }))
      process

      allow_any_instance_of(LeadQualifier).to receive(:call)
        .and_return(qualification(extracted_data: { "budget_eur" => 5000, "employees" => nil }))
      described_class.new(normalized_message("id" => "second")).call

      expect(Lead.last.extracted_data).to include("employees" => 40, "budget_eur" => 5000)
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
      expect(lead.score).to eq(0)
      expect(lead.verdict["reasoning"]).to eq("Abusive content.")
    end

    it "does not run the verdict router" do
      expect_any_instance_of(VerdictRouter).not_to receive(:call)
      process
    end
  end

  # Spec: "App degrades gracefully when the LLM is unavailable (fall back to
  # generic reply, tier: cold)".
  describe "when the AI is unavailable" do
    before do
      allow_any_instance_of(LeadQualifier).to receive(:call).and_return(
        qualification(fallback: true, extracted_data: {},
                      reasoning: "Anthropic API unavailable — generic acknowledgement sent.")
      )
    end

    it "records the lead as cold" do
      process
      lead = Lead.last

      expect(lead.tier).to eq(Lead::TIER_COLD)
      expect(lead.score).to eq(0)
      expect(lead.verdict["reasoning"]).to match(/unavailable/i)
    end

    it "still sends the generic acknowledgement" do
      expect(mailer).to receive(:send_follow_up)
      process
      expect(Lead.last.ai_reply_count).to eq(1)
    end

    it "leaves the lead in conversation so a later round can qualify it" do
      process
      expect(Lead.last.status).to eq(Lead::STATUS_IN_CONVERSATION)
    end

    it "does not run the website check or verdict routing" do
      expect_any_instance_of(VerdictRouter).not_to receive(:call)
      process
    end

    it "stops replying once the reply cap is reached" do
      process
      Lead.last.update!(ai_reply_count: Lead::MAX_AI_REPLIES)

      expect(mailer).not_to receive(:send_follow_up)
      described_class.new(normalized_message("id" => "second")).call

      expect(Lead.last.ai_reply_count).to eq(Lead::MAX_AI_REPLIES)
      expect(Lead.last.tier).to eq(Lead::TIER_COLD)
    end

    it "qualifies normally once the AI recovers" do
      process
      allow_any_instance_of(LeadQualifier).to receive(:call)
        .and_return(qualification(extracted_data: complete_extracted_data))
      expect_any_instance_of(VerdictRouter).to receive(:call)

      described_class.new(normalized_message("id" => "second")).call
    end
  end

  # Spec: verdict JSON is { tier, score, extracted_data, data_completeness,
  # reasoning, next_steps }.
  describe "verdict shape" do
    it "includes extracted_data and data_completeness on a red flag" do
      allow_any_instance_of(LeadQualifier).to receive(:call)
        .and_return(qualification(hostile: true, extracted_data: { "employees" => 40 }, reasoning: "Abusive."))
      process

      expect(Lead.last.verdict.keys)
        .to include("tier", "score", "extracted_data", "data_completeness", "reasoning", "next_steps")
      expect(Lead.last.verdict["extracted_data"]).to include("employees" => 40)
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
