require "rails_helper"

RSpec.describe WebsiteAnalyzer do
  def stub_fetcher(response)
    fetcher = instance_double(Inbound::SafeHttpFetcher, call: response)
    allow(Inbound::SafeHttpFetcher).to receive(:new).and_return(fetcher)
    fetcher
  end

  def http_response(body: "<html><head><title>Acme</title></head><body>Real business</body></html>", status: 200)
    Inbound::SafeHttpFetcher::Response.new(
      body:      body,
      status:    status,
      headers:   {},
      final_url: "https://acme.co"
    )
  end

  describe "URL handling" do
    it "treats a blank website as a no-fetch snapshot" do
      expect(Inbound::SafeHttpFetcher).not_to receive(:new)
      snapshot = described_class.new("").call

      expect(snapshot.fetched?).to be(false)
      expect(snapshot.fetch_error).to eq("No website supplied.")
    end

    it "is safe for nil" do
      expect(described_class.new(nil).call.fetched?).to be(false)
    end

    it "adds https:// to a bare domain" do
      stub_fetcher(http_response)
      expect(Inbound::SafeHttpFetcher).to receive(:new).with("https://acme.co").and_call_original
      described_class.new("acme.co").call
    end

    it "leaves an explicit scheme alone" do
      stub_fetcher(http_response)
      expect(Inbound::SafeHttpFetcher).to receive(:new).with("http://acme.co").and_call_original
      described_class.new("http://acme.co").call
    end
  end

  describe "a reachable site" do
    before { stub_fetcher(http_response) }

    it "returns a snapshot with title, description, and body" do
      snapshot = described_class.new("https://acme.co").call

      expect(snapshot.fetched?).to be(true)
      expect(snapshot.title).to eq("Acme")
      expect(snapshot.body).to include("Real business")
      expect(snapshot.fetch_error).to be_nil
    end

    it "reads the meta description when present" do
      stub_fetcher(http_response(
        body: %(<html><head><meta name="description" content="Consulting for enterprises"></head><body>hi</body></html>)
      ))
      expect(described_class.new("https://acme.co").call.description).to eq("Consulting for enterprises")
    end
  end

  describe "failures resolve to a snapshot with a fetch_error" do
    it "handles an HTTP error status" do
      stub_fetcher(http_response(status: 500))
      snapshot = described_class.new("https://acme.co").call

      expect(snapshot.fetched?).to be(false)
      expect(snapshot.fetch_error).to include("500")
    end

    it "handles an SSRF block from the fetcher" do
      allow(Inbound::SafeHttpFetcher).to receive(:new).and_return(
        instance_double(Inbound::SafeHttpFetcher).tap do |dbl|
          allow(dbl).to receive(:call).and_raise(Inbound::SafeHttpFetcher::BlockedError, "127.0.0.1 blocked")
        end
      )

      snapshot = described_class.new("http://localhost/").call
      expect(snapshot.fetched?).to be(false)
      expect(snapshot.fetch_error).to include("BlockedError")
      expect(snapshot.fetch_error).to include("blocked")
    end

    it "handles a fetcher redirect-loop error" do
      allow(Inbound::SafeHttpFetcher).to receive(:new).and_return(
        instance_double(Inbound::SafeHttpFetcher).tap do |dbl|
          allow(dbl).to receive(:call).and_raise(Inbound::SafeHttpFetcher::TooManyRedirectsError, "3 redirects")
        end
      )

      snapshot = described_class.new("https://redirects.example").call
      expect(snapshot.fetch_error).to include("TooManyRedirectsError")
    end

    it "handles a generic error without crashing" do
      allow(Inbound::SafeHttpFetcher).to receive(:new).and_return(
        instance_double(Inbound::SafeHttpFetcher).tap do |dbl|
          allow(dbl).to receive(:call).and_raise(SocketError, "getaddrinfo")
        end
      )

      snapshot = described_class.new("https://acme.co").call
      expect(snapshot.fetched?).to be(false)
      expect(snapshot.fetch_error).to include("SocketError")
    end
  end
end
