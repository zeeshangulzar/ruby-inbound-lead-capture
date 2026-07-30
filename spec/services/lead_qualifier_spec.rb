require "rails_helper"

RSpec.describe LeadQualifier do
  subject(:result) { described_class.new(lead: lead, incoming_body: body).call }

  let(:lead) do
    Lead.create!(thread_id: thread_id, sender_email: "sam@acme.co", sender_name: "Sam Prospect",
                 last_subject: "Interested in your consulting services")
  end
  let(:body) { "We're a 40-person team at acme.co, 5000 EUR budget, 40 hours." }

  let(:claude_json) do
    {
      extracted_data: {
        company: "Acme", website: "https://acme.co", employees: 40,
        budget_eur: 5000, budget_currency: "EUR", hours: 40
      },
      reply_subject: "Re: your enquiry",
      reply_text:    "Thanks Sam.\n\nMelissa",
      reply_html:    "<p>Thanks Sam.</p>",
      hostile:       false,
      off_topic:     false,
      reasoning:     "All fields supplied."
    }.to_json
  end

  def stub_claude(text)
    block    = instance_double(Anthropic::Models::TextBlock, text: text)
    response = instance_double(Anthropic::Models::Message, content: [block])
    messages = double(create: response)
    allow(Anthropic::Client).to receive(:new).and_return(double(messages: messages))
    messages
  end

  before { set_env("ANTHROPIC_API_KEY" => "test-key") }

  describe "a well-formed response" do
    before { stub_claude(claude_json) }

    it "extracts the qualification fields" do
      expect(result.extracted_data).to include(
        "company" => "Acme", "employees" => 40, "budget_eur" => 5000, "hours" => 40
      )
    end

    it "returns Melissa's reply" do
      expect(result.reply_subject).to eq("Re: your enquiry")
      expect(result.reply_text).to include("Melissa")
      expect(result.reply_html).to include("<p>")
    end

    it "is not a fallback" do
      expect(result).not_to be_fallback
    end

    it "drops keys outside the known schema" do
      stub_claude({ extracted_data: { company: "Acme", injected: "evil" } }.to_json)
      expect(result.extracted_data.keys).to all(be_in(%w[company website employees budget_eur budget_currency hours]))
    end
  end

  it "flags hostile email" do
    stub_claude({ hostile: true, reasoning: "Abusive." }.to_json)
    expect(result).to be_hostile
  end

  it "flags off-topic email" do
    stub_claude({ off_topic: true }.to_json)
    expect(result).to be_off_topic
  end

  it "tolerates prose wrapped around the JSON object" do
    stub_claude("Sure, here you go:\n```json\n#{claude_json}\n```\nHope that helps.")
    expect(result.extracted_data["company"]).to eq("Acme")
  end

  describe "graceful degradation" do
    it "falls back when the API errors, so a lead is never lost" do
      allow(Anthropic::Client).to receive(:new).and_raise(StandardError, "credit balance too low")

      expect(result).to be_fallback
      expect(result.extracted_data).to eq({})
      expect(result.reply_text).to include("get back to you")
      expect(result).not_to be_hostile
    end

    it "falls back on unparseable JSON" do
      stub_claude("not json at all")
      expect(result).to be_fallback
    end

    it "falls back on malformed JSON" do
      stub_claude("{ this is { not valid")
      expect(result).to be_fallback
    end

    it "titles the fallback reply from the lead's subject" do
      stub_claude("nonsense")
      expect(result.reply_subject).to eq("Re: Interested in your consulting services")
    end
  end

  describe "the request it sends" do
    it "passes the configured model and the system prompt" do
      set_env("ANTHROPIC_MODEL" => "claude-test-model")
      messages = stub_claude(claude_json)

      expect(messages).to receive(:create).with(
        hash_including(model: "claude-test-model", system: described_class::SYSTEM_PROMPT)
      ).and_return(
        instance_double(Anthropic::Models::Message,
                        content: [instance_double(Anthropic::Models::TextBlock, text: claude_json)])
      )

      result
    end

    it "tells Claude what has already been extracted, so it does not re-ask" do
      lead.update!(extracted_data: { "employees" => 40 })
      messages = stub_claude(claude_json)

      expect(messages).to receive(:create) do |args|
        expect(args[:messages].first[:content]).to include("employees")
        instance_double(Anthropic::Models::Message,
                        content: [instance_double(Anthropic::Models::TextBlock, text: claude_json)])
      end

      result
    end
  end
end
