require "rails_helper"

RSpec.describe Inbound::MessageNormalizer do
  def normalize(overrides = {})
    described_class.new(inbound_message(overrides)).call
  end

  it "pulls out the fields the pipeline needs" do
    result = normalize

    expect(result.inbox_id).to eq(inbox_id)
    expect(result.message_id).to eq(message_id)
    expect(result.thread_id).to eq(thread_id)
    expect(result.subject).to eq("Interested in your consulting services")
    expect(result.body_text).to include("40-person team")
  end

  describe "the from header, which arrives as one RFC-822 string" do
    it "splits a display name and address" do
      result = normalize("from" => "Dana Prospect <dana.prospect@gmail.com>")

      expect(result.sender_email).to eq("dana.prospect@gmail.com")
      expect(result.sender_name).to eq("Dana Prospect")
    end

    it "handles a bare address with no display name" do
      result = normalize("from" => "sam@acme.co")

      expect(result.sender_email).to eq("sam@acme.co")
      expect(result.sender_name).to eq("")
    end

    it "handles a quoted display name containing a comma" do
      result = normalize("from" => '"Prospect, Sam" <sam@acme.co>')

      expect(result.sender_email).to eq("sam@acme.co")
      expect(result.sender_name).to eq("Prospect, Sam")
    end

    it "downcases the address so lookups are consistent" do
      expect(normalize("from" => "Sam <SAM@ACME.CO>").sender_email).to eq("sam@acme.co")
    end

    it "falls back to an angle-bracket scan for malformed values" do
      result = normalize("from" => "Sam (broken <sam@acme.co>")

      expect(result.sender_email).to eq("sam@acme.co")
    end

    it "returns blanks for a missing from rather than raising" do
      result = normalize("from" => nil)

      expect(result.sender_email).to eq("")
      expect(result.sender_name).to eq("")
    end
  end

  describe "body" do
    it "prefers the plain-text part" do
      expect(normalize.body_text).to eq("We're a 40-person team at acme.co with a 5000 EUR budget for 40 hours.")
    end

    it "strips the HTML part when there is no text part" do
      result = normalize("text_body" => nil, "html_body" => "<p>Hello <b>there</b></p>")

      expect(result.body_text).to eq("Hello there")
    end

    it "is blank when the message has neither part" do
      expect(normalize("text_body" => nil, "html_body" => nil).body_text).to eq("")
    end
  end

  describe "thread_id" do
    it "falls back to the RFC Message-ID when Mailtrap sends no thread" do
      expect(normalize("thread_id" => nil).thread_id).to eq("<CAO0@mail.gmail.com>")
    end

    it "falls back to the message id when there is no thread or Message-ID" do
      expect(normalize("thread_id" => nil, "rfc_message_id" => nil).thread_id).to eq(message_id)
    end
  end

  describe "headers" do
    it "downcases keys" do
      expect(normalize("headers" => { "Auto-Submitted" => "auto-replied" }).headers)
        .to eq("auto-submitted" => "auto-replied")
    end

    it "accepts the name/value array form" do
      result = normalize("headers" => [{ "name" => "Precedence", "value" => "bulk" }])

      expect(result.headers).to eq("precedence" => "bulk")
    end

    it "is an empty hash when headers are absent" do
      expect(normalize("headers" => nil).headers).to eq({})
    end
  end
end
