require "rails_helper"

RSpec.describe Inbound::EventParser do
  def parse(payload)
    described_class.new(payload).message_received_events
  end

  it "extracts inbox_id and message_id from a message_received event" do
    events = parse("events" => [message_received_event])

    expect(events.size).to eq(1)
    expect(events.first.inbox_id).to eq(inbox_id)
    expect(events.first.message_id).to eq(message_id)
    expect(events.first.event_id).to eq("de1b5a49-8beb-11f1-8053-0a58a9feac02")
  end

  it "handles several events in one delivery" do
    events = parse("events" => [
      message_received_event,
      message_received_event("message_id" => "second-id")
    ])

    expect(events.map(&:message_id)).to eq([message_id, "second-id"])
  end

  it "ignores event types other than inbound.message_received" do
    expect(parse("events" => [message_received_event("event" => "inbound.something_else")])).to be_empty
  end

  it "skips events missing the ids needed to fetch the message" do
    expect(parse("events" => [message_received_event("message_id" => nil)])).to be_empty
    expect(parse("events" => [message_received_event("inbox_id" => nil)])).to be_empty
  end

  it "returns nothing for payloads without an events array" do
    expect(parse({})).to be_empty
    expect(parse("events" => nil)).to be_empty
    expect(parse(nil)).to be_empty
  end

  it "ignores non-hash entries rather than raising" do
    expect { parse("events" => ["garbage", nil]) }.not_to raise_error
    expect(parse("events" => ["garbage", nil])).to be_empty
  end

  it "coerces message_id to a string so it compares cleanly against the stored value" do
    events = parse("events" => [message_received_event("message_id" => 12_345)])
    expect(events.first.message_id).to eq("12345")
  end
end
