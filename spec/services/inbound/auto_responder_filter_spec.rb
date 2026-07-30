require "rails_helper"

RSpec.describe Inbound::AutoResponderFilter do
  def skip?(overrides = {})
    described_class.new(normalized_message(overrides)).skip?
  end

  it "lets an ordinary prospect email through" do
    expect(skip?).to be(false)
  end

  describe "no-reply senders" do
    it "skips mailer-daemon" do
      expect(skip?("from" => "mailer-daemon@example.com")).to be(true)
    end

    it "skips postmaster" do
      expect(skip?("from" => "postmaster@example.com")).to be(true)
    end

    it "skips no-reply and noreply" do
      expect(skip?("from" => "no-reply@example.com")).to be(true)
      expect(skip?("from" => "noreply@example.com")).to be(true)
    end

    it "skips suffixed noreply addresses" do
      expect(skip?("from" => "shop-noreply@example.com")).to be(true)
    end

    it "skips bounce addresses" do
      expect(skip?("from" => "bounce@example.com")).to be(true)
      expect(skip?("from" => "bounces@example.com")).to be(true)
    end

    it "matches case-insensitively" do
      expect(skip?("from" => "MAILER-DAEMON@EXAMPLE.COM")).to be(true)
    end

    it "does not skip a legitimate address that merely contains the word" do
      expect(skip?("from" => "sam@noreplytechnologies.com")).to be(false)
    end
  end

  describe "headers, when Mailtrap happens to expose them" do
    it "skips Auto-Submitted: auto-replied" do
      expect(skip?("headers" => { "Auto-Submitted" => "auto-replied" })).to be(true)
    end

    it "skips Auto-Submitted: auto-generated" do
      expect(skip?("headers" => { "auto-submitted" => "auto-generated" })).to be(true)
    end

    it "allows Auto-Submitted: no" do
      expect(skip?("headers" => { "auto-submitted" => "no" })).to be(false)
    end

    it "skips bulk and list precedence" do
      expect(skip?("headers" => { "Precedence" => "bulk" })).to be(true)
      expect(skip?("headers" => { "precedence" => "list" })).to be(true)
    end

    it "skips vendor auto-reply headers" do
      expect(skip?("headers" => { "x-autoreply" => "yes" })).to be(true)
      expect(skip?("headers" => { "x-autorespond" => "yes" })).to be(true)
    end
  end

  it "skips a message with no usable sender, since a reply would go nowhere" do
    expect(skip?("from" => nil)).to be(true)
  end

  # Mailtrap returns only a selected subset of headers, so the loop-prevention
  # headers are frequently absent even on genuine auto-replies.
  it "still processes a message whose headers Mailtrap stripped down" do
    expect(skip?("headers" => { "mime-version" => "1.0", "return-path" => "" })).to be(false)
  end
end
