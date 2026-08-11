require "rails_helper"

RSpec.describe FinalVerdict do
  subject(:result) do
    described_class.new(
      lead:             lead,
      website_snapshot: website_snapshot,
      prior_reasoning:  "Full data supplied."
    ).call
  end

  let(:lead) do
    Lead.create!(
      thread_id: thread_id, sender_email: "sam@acme.co", inbox_id: inbox_id,
      last_message_id: message_id, extracted_data: complete_extracted_data
    )
  end

  let(:claude_json) do
    {
      legitimate:      true,
      score:           85,
      reasoning:       "Consistent story between claim and site.",
      inconsistencies: [],
      next_steps:      ["Schedule an intro call."]
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

    it "returns the structured verdict" do
      expect(result.legitimate?).to be(true)
      expect(result.score).to eq(85)
      expect(result.reasoning).to include("Consistent")
      expect(result.next_steps).to include("Schedule an intro call.")
      expect(result.inconsistencies).to eq([])
    end

    it "is not a fallback" do
      expect(result).not_to be_fallback
    end

    it "clamps a score out of range" do
      stub_claude({ legitimate: true, score: 999, reasoning: "" }.to_json)
      expect(result.score).to eq(100)
    end

    it "clamps a negative score" do
      stub_claude({ legitimate: false, score: -20, reasoning: "" }.to_json)
      expect(result.score).to eq(0)
    end
  end

  describe "the prompt it builds" do
    it "includes the extracted lead data" do
      messages = stub_claude(claude_json)

      expect(messages).to receive(:create) do |args|
        content = args[:messages].first[:content]
        expect(content).to include("employees")
        expect(content).to include("40")
        expect(content).to include("budget_eur")
        instance_double(Anthropic::Models::Message,
                        content: [instance_double(Anthropic::Models::TextBlock, text: claude_json)])
      end

      result
    end

    it "includes the earlier qualifier reasoning" do
      messages = stub_claude(claude_json)

      expect(messages).to receive(:create) do |args|
        expect(args[:messages].first[:content]).to include("Full data supplied.")
        instance_double(Anthropic::Models::Message,
                        content: [instance_double(Anthropic::Models::TextBlock, text: claude_json)])
      end

      result
    end

    it "includes the website snapshot fields" do
      messages = stub_claude(claude_json)

      expect(messages).to receive(:create) do |args|
        content = args[:messages].first[:content]
        expect(content).to include("Acme")
        expect(content).to include("Consulting")
        instance_double(Anthropic::Models::Message,
                        content: [instance_double(Anthropic::Models::TextBlock, text: claude_json)])
      end

      result
    end
  end

  describe "graceful degradation" do
    it "falls back to not-legitimate when the API errors" do
      allow(Anthropic::Client).to receive(:new).and_raise(StandardError, "credit balance too low")

      expect(result).to be_fallback
      expect(result).not_to be_legitimate
      expect(result.reasoning).to include("unavailable")
    end

    it "falls back on unparseable JSON" do
      stub_claude("nothing json here")
      expect(result).to be_fallback
    end

    it "falls back on JSON parse error" do
      stub_claude("{ not valid json")
      expect(result).to be_fallback
    end
  end
end
