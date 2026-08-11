require "rails_helper"

RSpec.describe MelissaMailer do
  subject(:mailer) { described_class.new(lead: lead, api_client: api_client) }

  let(:lead) do
    Lead.create!(thread_id: thread_id, sender_email: "sam@acme.co", sender_name: "Sam Prospect",
                 inbox_id: inbox_id, last_message_id: message_id,
                 last_subject: "Interested in your consulting services")
  end
  let(:api_client) { instance_double(Inbound::ApiClient, reply: { "message_ids" => ["abc"] }) }

  describe "#send_follow_up" do
    let(:paragraphs) { ["Could you share your budget and team size?", "Talk soon."] }

    it "replies on the original message so Mailtrap threads it" do
      expect(api_client).to receive(:reply).with(hash_including(inbox_id: inbox_id, message_id: message_id))
      mailer.send_follow_up(reply_paragraphs: paragraphs)
    end

    it "renders the paragraphs into escaped HTML" do
      expect(api_client).to receive(:reply) do |args|
        expect(args[:html]).to include("<p>Could you share your budget and team size?</p>")
        expect(args[:html]).to include("<p>Talk soon.</p>")
        expect(args[:html]).to include("<p>Melissa</p>")
      end
      mailer.send_follow_up(reply_paragraphs: paragraphs)
    end

    it "escapes HTML characters supplied in the paragraph text" do
      expect(api_client).to receive(:reply) do |args|
        expect(args[:html]).to include("&lt;script&gt;alert(1)&lt;/script&gt;")
        expect(args[:html]).not_to include("<script>alert(1)</script>")
      end
      mailer.send_follow_up(reply_paragraphs: ["<script>alert(1)</script>"])
    end

    it "signs the text off as Melissa" do
      expect(api_client).to receive(:reply) do |args|
        expect(args[:text]).to include("Could you share your budget and team size?")
        expect(args[:text]).to include("Melissa")
      end
      mailer.send_follow_up(reply_paragraphs: paragraphs)
    end

    it "tags the message with a category" do
      expect(api_client).to receive(:reply).with(hash_including(category: "inbound-lead"))
      mailer.send_follow_up(reply_paragraphs: paragraphs)
    end

    it "returns :sent on success" do
      result = mailer.send_follow_up(reply_paragraphs: paragraphs)
      expect(result).to be_sent
      expect(result.error).to be_nil
    end

    it "returns :failed with no paragraphs to send" do
      expect(api_client).not_to receive(:reply)
      result = mailer.send_follow_up(reply_paragraphs: [])
      expect(result).to be_failed
      expect(result.error).to match(/empty/)
    end
  end

  describe "#send_qualified" do
    it "includes the scheduling link in both bodies" do
      expect(api_client).to receive(:reply) do |args|
        expect(args[:text]).to include("https://cal.example.com/melissa")
        expect(args[:html]).to include("https://cal.example.com/melissa")
      end

      mailer.send_qualified(scheduling_link: "https://cal.example.com/melissa")
    end

    it "signs off as Melissa" do
      expect(api_client).to receive(:reply) { |args| expect(args[:text]).to include("Melissa") }
      mailer.send_qualified(scheduling_link: "https://example.com/s")
    end

    it "returns :sent on success" do
      expect(mailer.send_qualified(scheduling_link: "https://example.com/s")).to be_sent
    end
  end

  describe "#send_forwarded" do
    it "copies the partner in" do
      expect(api_client).to receive(:reply).with(hash_including(cc: ["partner@acme.co"]))
      mailer.send_forwarded(partner_email: "partner@acme.co")
    end

    it "mentions the partner in the body" do
      expect(api_client).to receive(:reply) { |args| expect(args[:text]).to include("partner@acme.co") }
      mailer.send_forwarded(partner_email: "partner@acme.co")
    end

    # Mailtrap addresses the original sender itself and rejects the request if
    # an address appears twice, so a partner who is also the prospect must not
    # be CC'd: "address ... is not unique in the request".
    it "drops a CC that is already the recipient" do
      expect(api_client).to receive(:reply).with(hash_including(cc: []))
      mailer.send_forwarded(partner_email: lead.sender_email)
    end

    it "matches the recipient case-insensitively" do
      expect(api_client).to receive(:reply).with(hash_including(cc: []))
      mailer.send_forwarded(partner_email: lead.sender_email.upcase)
    end
  end

  describe "the from address" do
    it "is omitted by default, because Mailtrap-hosted inboxes reject it" do
      set_env("MELISSA_EMAIL" => nil)
      expect(api_client).to receive(:reply).with(hash_including(from: nil))
      mailer.send_follow_up(reply_paragraphs: ["Anything?"])
    end

    it "is set when a custom-domain sender is configured" do
      set_env("MELISSA_EMAIL" => "melissa@acme.co")
      expect(api_client).to receive(:reply).with(hash_including(from: "melissa@acme.co"))
      mailer.send_follow_up(reply_paragraphs: ["Anything?"])
    end
  end

  describe "when the lead cannot be replied to" do
    it "returns :failed without an inbox_id" do
      lead.update!(inbox_id: nil)
      expect(api_client).not_to receive(:reply)
      result = mailer.send_follow_up(reply_paragraphs: ["Anything?"])
      expect(result).to be_failed
    end

    it "returns :failed without a message id" do
      lead.update!(last_message_id: nil)
      expect(api_client).not_to receive(:reply)
      result = mailer.send_follow_up(reply_paragraphs: ["Anything?"])
      expect(result).to be_failed
    end
  end

  # A send failure must never break the pipeline — but it must be visible to
  # the caller so ai_reply_count and terminal status can be gated on it.
  it "returns :failed with the error when the API raises" do
    allow(api_client).to receive(:reply).and_raise(Inbound::ApiClient::Error, "HTTP 422")
    result = mailer.send_follow_up(reply_paragraphs: ["Anything?"])

    expect(result).to be_failed
    expect(result.error).to include("HTTP 422")
  end
end
