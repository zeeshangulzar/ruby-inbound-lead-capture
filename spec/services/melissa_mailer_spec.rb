require "rails_helper"

RSpec.describe MelissaMailer do
  subject(:mailer) { described_class.new(lead: lead, ai_content: qualification, api_client: api_client) }

  let(:lead) do
    Lead.create!(thread_id: thread_id, sender_email: "sam@acme.co", sender_name: "Sam Prospect",
                 inbox_id: inbox_id, last_message_id: message_id,
                 last_subject: "Interested in your consulting services")
  end
  let(:api_client) { instance_double(Inbound::ApiClient, reply: { "message_ids" => ["abc"] }) }

  describe "#send_follow_up" do
    it "replies on the original message so Mailtrap threads it" do
      expect(api_client).to receive(:reply).with(hash_including(inbox_id: inbox_id, message_id: message_id))
      mailer.send_follow_up
    end

    it "sends the AI-drafted text and html" do
      expect(api_client).to receive(:reply).with(
        hash_including(text: qualification.reply_text, html: qualification.reply_html)
      )
      mailer.send_follow_up
    end

    it "tags the message with a category" do
      expect(api_client).to receive(:reply).with(hash_including(category: "inbound-lead"))
      mailer.send_follow_up
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
  end

  describe "the from address" do
    it "is omitted by default, because Mailtrap-hosted inboxes reject it" do
      expect(api_client).to receive(:reply).with(hash_including(from: nil))
      mailer.send_follow_up
    end

    it "is set when a custom-domain sender is configured" do
      set_env("MELISSA_EMAIL" => "melissa@acme.co")
      expect(api_client).to receive(:reply).with(hash_including(from: "melissa@acme.co"))
      mailer.send_follow_up
    end
  end

  describe "when the lead cannot be replied to" do
    it "logs and does nothing without an inbox_id" do
      lead.update!(inbox_id: nil)
      expect(api_client).not_to receive(:reply)
      expect { mailer.send_follow_up }.not_to raise_error
    end

    it "logs and does nothing without a message id" do
      lead.update!(last_message_id: nil)
      expect(api_client).not_to receive(:reply)
      expect { mailer.send_follow_up }.not_to raise_error
    end
  end

  # A send failure must never break the pipeline: the lead is already saved and
  # the verdict recorded by the time we try to reply.
  it "swallows and logs an API error" do
    allow(api_client).to receive(:reply).and_raise(Inbound::ApiClient::Error, "HTTP 422")
    expect(Rails.logger).to receive(:error).with(/reply failed/)
    expect { mailer.send_follow_up }.not_to raise_error
  end
end
