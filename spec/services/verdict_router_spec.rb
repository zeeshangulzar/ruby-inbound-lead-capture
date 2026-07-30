require "rails_helper"

RSpec.describe VerdictRouter do
  subject(:route) { described_class.new(lead: lead).call }

  let(:lead) do
    Lead.create!(
      thread_id: thread_id, sender_email: "sam@acme.co", inbox_id: inbox_id,
      last_message_id: message_id, extracted_data: complete_extracted_data
    )
  end
  let(:mailer) { instance_double(MelissaMailer, send_qualified: nil, send_forwarded: nil) }

  before do
    allow(MelissaMailer).to receive(:new).and_return(mailer)
    allow(HubspotSync).to receive(:new).and_return(instance_double(HubspotSync, call: nil))
    stub_website(legitimate: true, reasoning: "Real business.")
  end

  def stub_website(legitimate:, reasoning: "")
    allow_any_instance_of(WebsiteAnalyzer).to receive(:call).and_return(
      WebsiteAnalyzer::Result.new(legitimate: legitimate, reasoning: reasoning, fetch_error: false)
    )
  end

  describe "an illegitimate website" do
    before { stub_website(legitimate: false, reasoning: "Parked domain.") }

    it "red-flags without replying" do
      expect(mailer).not_to receive(:send_qualified)
      expect(mailer).not_to receive(:send_forwarded)
      route

      expect(lead.reload.status).to eq(Lead::STATUS_RED_FLAGGED)
      expect(lead.tier).to eq(Lead::TIER_RED_FLAG)
      expect(lead.score).to eq(0)
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
      expect(mailer).to receive(:send_forwarded).with(partner_email: "partner@acme.co")
      route

      expect(lead.reload.tier).to eq(Lead::TIER_FORWARDED)
      expect(lead.status).to eq(Lead::STATUS_FINALIZED)
    end

    it "forwards when the budget is too low" do
      lead.update!(extracted_data: complete_extracted_data.merge("budget_eur" => 100))
      route
      expect(lead.reload.tier).to eq(Lead::TIER_FORWARDED)
    end

    it "forwards when the hours are too few" do
      lead.update!(extracted_data: complete_extracted_data.merge("hours" => 2))
      route
      expect(lead.reload.tier).to eq(Lead::TIER_FORWARDED)
    end

    it "does not push a forwarded lead to HubSpot" do
      lead.update!(extracted_data: complete_extracted_data.merge("employees" => 5))
      expect(HubspotSync).not_to receive(:new)
      route
    end

    it "names the partner in the next steps" do
      lead.update!(extracted_data: complete_extracted_data.merge("employees" => 5))
      route
      expect(lead.reload.verdict["next_steps"].join).to include("partner@acme.co")
    end
  end

  describe "passing every threshold" do
    before { set_env("SCHEDULING_LINK" => "https://cal.example.com/melissa") }

    it "replies with the scheduling link" do
      expect(mailer).to receive(:send_qualified).with(scheduling_link: "https://cal.example.com/melissa")
      route

      expect(lead.reload.status).to eq(Lead::STATUS_FINALIZED)
      expect(lead.tier).to be_in([Lead::TIER_HOT, Lead::TIER_WARM, Lead::TIER_COLD])
    end

    it "scores a strong lead hot" do
      lead.update!(extracted_data: complete_extracted_data.merge(
        "employees" => 500, "budget_eur" => 50_000, "hours" => 200
      ))
      route

      expect(lead.reload.tier).to eq(Lead::TIER_HOT)
      expect(lead.score).to eq(100)
    end

    it "records the website reasoning" do
      route
      expect(lead.reload.verdict["reasoning"]).to include("Real business.")
    end

    it "marks completeness full when all fields are present" do
      route
      expect(lead.reload.verdict["data_completeness"]).to eq("full")
    end

    describe "HubSpot" do
      it "stores the returned contact id" do
        allow(HubspotSync).to receive(:new).and_return(instance_double(HubspotSync, call: "contact-123"))
        route
        expect(lead.reload.hubspot_contact_id).to eq("contact-123")
      end

      it "still finalizes the lead when HubSpot returns nothing" do
        allow(HubspotSync).to receive(:new).and_return(instance_double(HubspotSync, call: nil))
        route

        expect(lead.reload.hubspot_contact_id).to be_nil
        expect(lead.status).to eq(Lead::STATUS_FINALIZED)
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
