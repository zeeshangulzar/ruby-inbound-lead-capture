require "rails_helper"

RSpec.describe VerdictRouter do
  subject(:route) { described_class.new(lead: lead, prior_reasoning: "Earlier reasoning.").call }

  let(:lead) do
    Lead.create!(
      thread_id: thread_id, sender_email: "sam@acme.co", inbox_id: inbox_id,
      last_message_id: message_id, extracted_data: complete_extracted_data
    )
  end
  let(:mailer) do
    instance_double(MelissaMailer,
                    send_qualified: MelissaMailer::Result.new(status: :sent, error: nil),
                    send_forwarded: MelissaMailer::Result.new(status: :sent, error: nil))
  end

  before do
    allow(MelissaMailer).to receive(:new).and_return(mailer)
    allow(HubspotSync).to receive(:new).and_return(instance_double(HubspotSync, call: nil))
    allow(WebsiteAnalyzer).to receive(:new).and_return(instance_double(WebsiteAnalyzer, call: website_snapshot))
    stub_verdict(final_verdict(legitimate: true, score: 90))
  end

  def stub_verdict(verdict)
    allow(FinalVerdict).to receive(:new).and_return(instance_double(FinalVerdict, call: verdict))
  end

  describe "an illegitimate website" do
    before { stub_verdict(final_verdict(legitimate: false, score: 10, reasoning: "Parked domain.")) }

    it "red-flags without replying" do
      expect(mailer).not_to receive(:send_qualified)
      expect(mailer).not_to receive(:send_forwarded)
      route

      expect(lead.reload.status).to eq(Lead::STATUS_RED_FLAGGED)
      expect(lead.tier).to eq(Lead::TIER_RED_FLAG)
      expect(lead.verdict["reasoning"]).to eq("Parked domain.")
    end

    it "never reaches HubSpot" do
      expect(HubspotSync).not_to receive(:new)
      route
    end
  end

  describe "below a threshold" do
    before { set_env("PARTNER_EMAIL" => "partner@acme.co") }

    it "forwards when the team is too small" do
      lead.update!(extracted_data: complete_extracted_data.merge("employees" => 5))
      expect(mailer).to receive(:send_forwarded).with(partner_email: "partner@acme.co").and_return(
        MelissaMailer::Result.new(status: :sent, error: nil)
      )
      route

      expect(lead.reload.tier).to eq(Lead::TIER_FORWARDED)
      expect(lead.status).to eq(Lead::STATUS_FINALIZED)
      expect(lead.last_reply_status).to eq(Lead::REPLY_STATUS_SENT)
    end

    it "does not push a forwarded lead to HubSpot" do
      lead.update!(extracted_data: complete_extracted_data.merge("employees" => 5))
      expect(HubspotSync).not_to receive(:new)
      route
    end

    it "increments ai_reply_count on a successful forwarded reply" do
      lead.update!(extracted_data: complete_extracted_data.merge("employees" => 5))
      expect { route }.to change { lead.reload.ai_reply_count }.by(1)
    end

    it "does not finalize when the reply fails" do
      lead.update!(extracted_data: complete_extracted_data.merge("employees" => 5))
      allow(mailer).to receive(:send_forwarded).and_return(
        MelissaMailer::Result.new(status: :failed, error: "HTTP 500")
      )

      expect { route }.not_to change { lead.reload.ai_reply_count }
      expect(lead.reload.status).not_to eq(Lead::STATUS_FINALIZED)
      expect(lead.last_reply_status).to eq(Lead::REPLY_STATUS_FAILED)
      expect(lead.last_reply_error).to eq("HTTP 500")
    end
  end

  describe "passing every threshold" do
    before { set_env("SCHEDULING_LINK" => "https://cal.example.com/melissa") }

    it "replies with the scheduling link and finalizes" do
      expect(mailer).to receive(:send_qualified).with(scheduling_link: "https://cal.example.com/melissa").and_return(
        MelissaMailer::Result.new(status: :sent, error: nil)
      )
      route

      expect(lead.reload.status).to eq(Lead::STATUS_FINALIZED)
      expect(lead.last_reply_status).to eq(Lead::REPLY_STATUS_SENT)
    end

    it "does not finalize or push to HubSpot when the reply fails" do
      allow(mailer).to receive(:send_qualified).and_return(
        MelissaMailer::Result.new(status: :failed, error: "HTTP 502")
      )
      expect(HubspotSync).not_to receive(:new)

      route

      expect(lead.reload.status).not_to eq(Lead::STATUS_FINALIZED)
      expect(lead.ai_reply_count).to eq(0)
      expect(lead.last_reply_status).to eq(Lead::REPLY_STATUS_FAILED)
      expect(lead.last_reply_error).to eq("HTTP 502")
    end

    it "combines threshold and AI score into the final score" do
      lead.update!(extracted_data: complete_extracted_data.merge(
        "employees" => 500, "budget_eur" => 50_000, "hours" => 200
      ))
      stub_verdict(final_verdict(legitimate: true, score: 80))
      route

      expect(lead.reload.score).to eq(90)
      expect(lead.tier).to eq(Lead::TIER_HOT)
    end

    it "carries the FinalVerdict reasoning into the stored verdict" do
      route
      expect(lead.reload.verdict["reasoning"]).to include("Real business.")
    end

    it "carries FinalVerdict inconsistencies through" do
      stub_verdict(final_verdict(legitimate: true, score: 70, inconsistencies: ["Employees claim vs. site scale"]))
      route

      expect(lead.reload.verdict["inconsistencies"]).to eq(["Employees claim vs. site scale"])
    end

    describe "HubSpot" do
      it "stores the returned contact id after a successful reply" do
        allow(HubspotSync).to receive(:new).and_return(instance_double(HubspotSync, call: "contact-123"))
        route
        expect(lead.reload.hubspot_contact_id).to eq("contact-123")
      end
    end
  end

  describe "thresholds are configurable" do
    it "honours raised minimums" do
      set_env("MIN_EMPLOYEES" => "1000")
      route
      expect(lead.reload.tier).to eq(Lead::TIER_FORWARDED)
    end
  end

  describe "missing or non-numeric values" do
    it "treats a nil number as zero and forwards rather than crashing" do
      lead.update!(extracted_data: complete_extracted_data.merge("employees" => nil))
      expect { route }.not_to raise_error
      expect(lead.reload.tier).to eq(Lead::TIER_FORWARDED)
    end

    it "treats unparseable text as zero" do
      lead.update!(extracted_data: complete_extracted_data.merge("budget_eur" => "lots"))
      route
      expect(lead.reload.tier).to eq(Lead::TIER_FORWARDED)
    end

    it "accepts numbers supplied as strings" do
      lead.update!(extracted_data: complete_extracted_data.merge("employees" => "40"))
      route
      expect(lead.reload.tier).not_to eq(Lead::TIER_FORWARDED)
    end
  end
end
