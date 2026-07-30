require "rails_helper"

RSpec.describe HubspotSync do
  subject(:sync) { described_class.new(lead: lead).call }

  let(:lead) do
    Lead.create!(thread_id: thread_id, sender_email: "sam@acme.co", sender_name: "Sam Prospect",
                 extracted_data: complete_extracted_data)
  end

  let(:contacts_api) { double }

  def stub_hubspot(result)
    allow(Hubspot::Client).to receive(:new).and_return(
      double(crm: double(contacts: double(basic_api: contacts_api)))
    )
    if result.is_a?(StandardError)
      allow(contacts_api).to receive(:create).and_raise(result)
    else
      allow(contacts_api).to receive(:create).and_return(result)
    end
  end

  describe "when no API key is configured" do
    it "skips silently rather than erroring" do
      set_env("HUBSPOT_API_KEY" => nil)
      expect(Hubspot::Client).not_to receive(:new)
      expect(sync).to be_nil
    end

    it "also skips for a blank key" do
      set_env("HUBSPOT_API_KEY" => "")
      expect(Hubspot::Client).not_to receive(:new)
      expect(sync).to be_nil
    end
  end

  describe "with an API key" do
    before { set_env("HUBSPOT_API_KEY" => "pat-test-123") }

    it "returns the created contact id" do
      stub_hubspot(double(id: "contact-999"))
      expect(sync).to eq("contact-999")
    end

    # HubSpot rejects the whole create with a 400 if any property name is
    # unknown. `numemployees` is the contact property; `numberofemployees` is
    # the company one and would fail here.
    it "uses the numemployees contact property" do
      stub_hubspot(double(id: "c1"))
      expect(contacts_api).to receive(:create) do |args|
        expect(args[:body][:properties]).to have_key(:numemployees)
        expect(args[:body][:properties]).not_to have_key(:numberofemployees)
        double(id: "c1")
      end

      sync
    end

    # numemployees is a dropdown, not a number. Sending the raw count fails
    # with "40 was not one of the allowed options: [1-5, 5-25, ...]".
    describe "employee count is mapped to a HubSpot bucket" do
      def sent_bucket(employees)
        stub_hubspot(double(id: "c1"))
        captured = nil
        allow(contacts_api).to receive(:create) do |args|
          captured = args[:body][:properties][:numemployees]
          double(id: "c1")
        end
        lead.update!(extracted_data: complete_extracted_data.merge("employees" => employees))
        described_class.new(lead: lead).call
        captured
      end

      it "never sends a raw integer" do
        expect(sent_bucket(40)).to be_a(String)
      end

      {
        1    => "1-5",
        5    => "1-5",
        6    => "5-25",
        25   => "5-25",
        40   => "25-50",
        50   => "25-50",
        60   => "50-100",
        100  => "50-100",
        500  => "100-500",
        1000 => "500-1000",
        5000 => "1000+"
      }.each do |count, bucket|
        it "maps #{count} to #{bucket}" do
          expect(sent_bucket(count)).to eq(bucket)
        end
      end

      it "accepts a count supplied as a string" do
        expect(sent_bucket("40")).to eq("25-50")
      end

      it "omits the property when the count is missing" do
        expect(sent_bucket(nil)).to be_nil
      end

      it "omits the property when the count is not a number" do
        expect(sent_bucket("lots")).to be_nil
      end
    end

    it "maps the lead onto contact properties" do
      stub_hubspot(double(id: "c1"))
      expect(contacts_api).to receive(:create) do |args|
        expect(args[:body][:properties]).to include(
          email: "sam@acme.co", firstname: "Sam", lastname: "Prospect",
          company: "Acme", website: "https://acme.co", hs_lead_status: "NEW"
        )
        double(id: "c1")
      end

      sync
    end

    it "splits a single-word name without a surname" do
      lead.update!(sender_name: "Sam")
      stub_hubspot(double(id: "c1"))
      expect(contacts_api).to receive(:create) do |args|
        expect(args[:body][:properties][:firstname]).to eq("Sam")
        expect(args[:body][:properties]).not_to have_key(:lastname)
        double(id: "c1")
      end

      sync
    end

    it "omits name properties when the sender name is blank" do
      lead.update!(sender_name: "")
      stub_hubspot(double(id: "c1"))
      expect(contacts_api).to receive(:create) do |args|
        expect(args[:body][:properties]).not_to have_key(:firstname)
        double(id: "c1")
      end

      sync
    end

    # Fail-open: a CRM outage must not cost us the lead or the reply.
    it "returns nil and logs when HubSpot errors" do
      stub_hubspot(StandardError.new("502 Bad Gateway"))
      expect(Rails.logger).to receive(:error).with(/HubspotSync/)
      expect(sync).to be_nil
    end
  end
end
