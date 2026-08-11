require "rails_helper"

RSpec.describe Inbound::SafeHttpFetcher do
  def stub_dns(host, addresses)
    allow(Resolv).to receive(:getaddresses).with(host).and_return(addresses)
  end

  def stub_net_http(response)
    http = double("Net::HTTP")
    allow(http).to receive(:request).and_yield(response)
    allow(Net::HTTP).to receive(:start).and_yield(http)
    http
  end

  def http_response(status:, body: "", location: nil)
    headers = []
    headers << ["location", location] if location
    headers << ["content-length", body.bytesize.to_s]

    response = double("Net::HTTPResponse", code: status.to_s, each_header: headers)
    allow(response).to receive(:read_body).and_yield(body)
    allow(response).to receive(:[]) do |key|
      headers.find { |h| h[0].downcase == key.to_s.downcase }&.last
    end
    response
  end

  describe "URL validation" do
    it "rejects a non-HTTP scheme" do
      expect { described_class.new("ftp://acme.co/").call }
        .to raise_error(described_class::BlockedError, /unsupported scheme/)
    end

    it "rejects file:// URLs" do
      expect { described_class.new("file:///etc/passwd").call }
        .to raise_error(described_class::BlockedError)
    end

    it "rejects a URL with no host" do
      expect { described_class.new("http:///path").call }
        .to raise_error(described_class::BlockedError, /host/)
    end
  end

  describe "IPv4 blocklist" do
    [
      "127.0.0.1",
      "10.0.0.1",
      "192.168.1.1",
      "172.16.5.5",
      "169.254.169.254",
      "100.64.0.1",
      "0.0.0.0",
      "224.0.0.1",
      "240.0.0.1"
    ].each do |address|
      it "rejects a host resolving to #{address}" do
        stub_dns("attacker.example", [address])
        expect { described_class.new("http://attacker.example/").call }
          .to raise_error(described_class::BlockedError, /blocked address/)
      end
    end
  end

  describe "IPv6 blocklist" do
    [
      "::1",
      "fe80::1",
      "fc00::1",
      "::ffff:127.0.0.1"
    ].each do |address|
      it "rejects a host resolving to #{address}" do
        stub_dns("attacker.example", [address])
        expect { described_class.new("http://attacker.example/").call }
          .to raise_error(described_class::BlockedError)
      end
    end
  end

  describe "belt-and-suspenders" do
    it "rejects when any resolved address is blocked, even if others look public" do
      stub_dns("attacker.example", ["8.8.8.8", "127.0.0.1"])
      expect { described_class.new("http://attacker.example/").call }
        .to raise_error(described_class::BlockedError, /127.0.0.1/)
    end

    it "rejects when the host cannot be resolved" do
      allow(Resolv).to receive(:getaddresses).and_raise(Resolv::ResolvError)
      expect { described_class.new("http://nowhere.example/").call }
        .to raise_error(described_class::BlockedError, /resolve/)
    end
  end

  describe "redirects" do
    it "revalidates the target host on every redirect and blocks a redirect into private space" do
      stub_dns("acme.co", ["93.184.216.34"])
      stub_dns("evil.example", ["127.0.0.1"])

      stub_net_http(http_response(status: 302, location: "http://evil.example/"))

      expect { described_class.new("http://acme.co/").call }
        .to raise_error(described_class::BlockedError, /127.0.0.1/)
    end

    it "aborts after too many hops" do
      stub_dns("acme.co", ["93.184.216.34"])
      stub_net_http(http_response(status: 302, location: "http://acme.co/next"))

      expect { described_class.new("http://acme.co/").call }
        .to raise_error(described_class::TooManyRedirectsError)
    end
  end

  describe "successful fetch" do
    before do
      stub_dns("acme.co", ["93.184.216.34"])
      stub_net_http(http_response(status: 200, body: "hello world"))
    end

    it "returns a Response with body and status" do
      response = described_class.new("http://acme.co/").call
      expect(response.status).to eq(200)
      expect(response.body).to eq("hello world")
      expect(response).to be_success
    end
  end

  describe "size cap" do
    before { stub_dns("acme.co", ["93.184.216.34"]) }

    it "raises when the streamed body exceeds the cap" do
      body     = "a" * 10
      response = double("Net::HTTPResponse", code: "200", each_header: [["content-length", "10"]])
      allow(response).to receive(:read_body).and_yield("a" * 6).and_yield("a" * 6)
      allow(response).to receive(:[]).with("content-length").and_return("10")

      http = double("Net::HTTP")
      allow(http).to receive(:request).and_yield(response)
      allow(Net::HTTP).to receive(:start).and_yield(http)

      expect { described_class.new("http://acme.co/", max_bytes: 8).call }
        .to raise_error(described_class::ResponseTooLargeError)
    end
  end
end
