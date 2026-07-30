require "rails_helper"

RSpec.describe Inbound::SignatureVerifier do
  let(:body) { webhook_body }

  before { set_env("MAILTRAP_INBOUND_SECRET" => secret) }

  it "reads the header name Mailtrap actually sends" do
    expect(described_class::HEADER_NAME).to eq("Mailtrap-Signature")
  end

  it "accepts a correctly signed body" do
    expect(described_class.new(body, signature_for(body))).to be_valid
  end

  it "rejects a signature computed with a different secret" do
    expect(described_class.new(body, signature_for(body, secret: "other-secret"))).not_to be_valid
  end

  it "rejects a body that changed after signing" do
    signature = signature_for(body)
    expect(described_class.new("#{body} ", signature)).not_to be_valid
  end

  it "rejects a missing signature" do
    expect(described_class.new(body, "")).not_to be_valid
  end

  it "rejects a signature of the wrong length without raising" do
    expect { described_class.new(body, "deadbeef").valid? }.not_to raise_error
    expect(described_class.new(body, "deadbeef")).not_to be_valid
  end

  it "rejects non-hex characters of the right length without raising" do
    expect(described_class.new(body, "z" * 64)).not_to be_valid
  end

  it "rejects everything when the secret is not configured" do
    set_env("MAILTRAP_INBOUND_SECRET" => nil)
    expect(described_class.new(body, signature_for(body))).not_to be_valid
  end
end
