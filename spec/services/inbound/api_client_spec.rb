require "rails_helper"

RSpec.describe Inbound::ApiClient do
  subject(:client) { described_class.new(api_token: api_token) }

  let(:ok) { instance_double(HTTParty::Response, success?: true, parsed_response: { "id" => message_id }) }

  describe "#fetch_message" do
    it "GETs the inbound message endpoint with the Api-Token header" do
      expect(HTTParty).to receive(:get).with(
        "https://mailtrap.io/api/inbound/inboxes/#{inbox_id}/messages/#{message_id}",
        hash_including(headers: hash_including("Api-Token" => api_token))
      ).and_return(ok)

      expect(client.fetch_message(inbox_id: inbox_id, message_id: message_id)).to eq("id" => message_id)
    end

    it "raises on a non-success response" do
      allow(HTTParty).to receive(:get).and_return(
        instance_double(HTTParty::Response, success?: false, code: 404, body: "not found")
      )

      expect { client.fetch_message(inbox_id: inbox_id, message_id: message_id) }
        .to raise_error(described_class::Error, /HTTP 404/)
    end
  end

  describe "#reply" do
    def reply(**extra)
      client.reply(inbox_id: inbox_id, message_id: message_id, text: "hi", html: "<p>hi</p>", **extra)
    end

    it "POSTs to the reply endpoint so Mailtrap threads the response" do
      expect(HTTParty).to receive(:post).with(
        "https://mailtrap.io/api/inbound/inboxes/#{inbox_id}/messages/#{message_id}/reply",
        any_args
      ).and_return(ok)

      reply
    end

    it "sends the text and html bodies" do
      allow(HTTParty).to receive(:post) do |_url, options|
        expect(JSON.parse(options[:body])).to include("text" => "hi", "html" => "<p>hi</p>")
        ok
      end

      reply
    end

    it "omits from by default, because hosted inboxes reject it" do
      allow(HTTParty).to receive(:post) do |_url, options|
        expect(JSON.parse(options[:body])).not_to have_key("from")
        ok
      end

      reply
    end

    it "includes from when a custom-domain sender is supplied" do
      allow(HTTParty).to receive(:post) do |_url, options|
        expect(JSON.parse(options[:body])["from"]).to eq("email" => "melissa@acme.co", "name" => "Melissa")
        ok
      end

      reply(from: "melissa@acme.co")
    end

    it "maps cc addresses to the {email} shape the API expects" do
      allow(HTTParty).to receive(:post) do |_url, options|
        expect(JSON.parse(options[:body])["cc"]).to eq([{ "email" => "partner@acme.co" }])
        ok
      end

      reply(cc: ["partner@acme.co"])
    end

    it "omits cc when there are no addresses" do
      allow(HTTParty).to receive(:post) do |_url, options|
        expect(JSON.parse(options[:body])).not_to have_key("cc")
        ok
      end

      reply(cc: [])
    end

    it "passes the category through" do
      allow(HTTParty).to receive(:post) do |_url, options|
        expect(JSON.parse(options[:body])["category"]).to eq("inbound-lead")
        ok
      end

      reply(category: "inbound-lead")
    end

    it "raises on a non-success response" do
      allow(HTTParty).to receive(:post).and_return(
        instance_double(HTTParty::Response, success?: false, code: 422, body: "bad from")
      )

      expect { reply }.to raise_error(described_class::Error, /HTTP 422/)
    end
  end

  it "falls back to MAILTRAP_API_TOKEN when no token is passed" do
    set_env("MAILTRAP_API_TOKEN" => "from-env")
    allow(HTTParty).to receive(:get) do |_url, options|
      expect(options[:headers]["Api-Token"]).to eq("from-env")
      ok
    end

    described_class.new.fetch_message(inbox_id: inbox_id, message_id: message_id)
  end
end
