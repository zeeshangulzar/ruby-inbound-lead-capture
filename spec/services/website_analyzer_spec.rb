require "rails_helper"

RSpec.describe WebsiteAnalyzer do
  before { set_env("ANTHROPIC_API_KEY" => "test-key") }

  def stub_page(body: "<html><head><title>Acme</title></head><body>Real business</body></html>", success: true, code: 200)
    allow(HTTParty).to receive(:get).and_return(
      instance_double(HTTParty::Response, success?: success, code: code, body: body)
    )
  end

  def stub_verdict(text)
    block    = instance_double(Anthropic::Models::TextBlock, text: text)
    response = instance_double(Anthropic::Models::Message, content: [block])
    allow(Anthropic::Client).to receive(:new).and_return(double(messages: double(create: response)))
  end

  describe "URL handling" do
    it "treats a blank website as not legitimate without any network call" do
      expect(HTTParty).not_to receive(:get)
      result = described_class.new("").call

      expect(result).not_to be_legitimate
      expect(result.reasoning).to eq("No website supplied.")
    end

    it "is also safe for nil" do
      expect(described_class.new(nil).call).not_to be_legitimate
    end

    # A bare domain parses to a URI with no host, so HTTParty would try to
    # connect to nil:80 and every such lead would be red-flagged.
    it "adds https:// to a bare domain" do
      stub_verdict({ legitimate: true, reasoning: "Looks real." }.to_json)
      expect(HTTParty).to receive(:get).with("https://acme.co", any_args).and_return(
        instance_double(HTTParty::Response, success?: true, code: 200, body: "<html><body>hi</body></html>")
      )

      described_class.new("acme.co").call
    end

    it "leaves an explicit scheme alone" do
      stub_verdict({ legitimate: true, reasoning: "Looks real." }.to_json)
      expect(HTTParty).to receive(:get).with("http://acme.co", any_args).and_return(
        instance_double(HTTParty::Response, success?: true, code: 200, body: "<html><body>hi</body></html>")
      )

      described_class.new("http://acme.co").call
    end
  end

  describe "a reachable site" do
    before { stub_page }

    it "returns Claude's positive verdict" do
      stub_verdict({ legitimate: true, reasoning: "Established consultancy." }.to_json)
      result = described_class.new("https://acme.co").call

      expect(result).to be_legitimate
      expect(result.reasoning).to eq("Established consultancy.")
      expect(result.fetch_error).to be(false)
    end

    it "returns Claude's negative verdict" do
      stub_verdict({ legitimate: false, reasoning: "Parked domain." }.to_json)
      expect(described_class.new("https://acme.co").call).not_to be_legitimate
    end

    it "does not treat a missing legitimate flag as legitimate" do
      stub_verdict({ reasoning: "Unclear." }.to_json)
      expect(described_class.new("https://acme.co").call).not_to be_legitimate
    end
  end

  describe "failures all resolve to not legitimate" do
    it "handles an HTTP error status" do
      stub_page(success: false, code: 500)
      result = described_class.new("https://acme.co").call

      expect(result).not_to be_legitimate
      expect(result.fetch_error).to be(true)
      expect(result.reasoning).to include("500")
    end

    it "handles a refused connection" do
      allow(HTTParty).to receive(:get).and_raise(Errno::ECONNREFUSED)
      expect(described_class.new("https://acme.co").call.fetch_error).to be(true)
    end

    it "handles a read timeout" do
      allow(HTTParty).to receive(:get).and_raise(Net::ReadTimeout)
      expect(described_class.new("https://acme.co").call.fetch_error).to be(true)
    end

    it "handles a TLS failure" do
      allow(HTTParty).to receive(:get).and_raise(OpenSSL::SSL::SSLError, "bad cert")
      result = described_class.new("https://acme.co").call

      expect(result).not_to be_legitimate
      expect(result.reasoning).to include("SSLError")
    end

    it "handles unparseable JSON from Claude" do
      stub_page
      stub_verdict("I think it looks fine, honestly")
      result = described_class.new("https://acme.co").call

      expect(result).not_to be_legitimate
      expect(result.reasoning).to eq("Verdict parse error.")
    end

    it "handles a response with no JSON object at all" do
      stub_page
      stub_verdict("")
      expect(described_class.new("https://acme.co").call.reasoning).to eq("Verdict parse error.")
    end
  end
end
