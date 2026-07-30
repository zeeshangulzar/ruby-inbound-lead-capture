# Shared builders for the Mailtrap Inbound shapes.
#
# The payloads here mirror what Mailtrap actually sends and returns — the
# webhook envelope carries only ids, and the message body comes back from the
# Messages API with `from` as a single RFC-822 string.
module InboundHelpers
  INBOX_ID   = 695
  MESSAGE_ID = "1872125554587900000".freeze
  THREAD_ID  = "1872125554587900001".freeze
  # Dummy value with the shape of a real signing secret (32 hex characters).
  SECRET     = "0123456789abcdef0123456789abcdef".freeze
  API_TOKEN  = "test-api-token".freeze

  # Readers, so examples can use these without the module prefix (constants are
  # not resolvable by bare name from inside an example block).
  def inbox_id
    INBOX_ID
  end

  def message_id
    MESSAGE_ID
  end

  def thread_id
    THREAD_ID
  end

  def secret
    SECRET
  end

  def api_token
    API_TOKEN
  end

  # A message as returned by GET /api/inbound/inboxes/:inbox_id/messages/:id
  def inbound_message(overrides = {})
    {
      "id"             => MESSAGE_ID,
      "inbox_id"       => INBOX_ID,
      "from"           => "Sam Prospect <sam@acme.co>",
      "to"             => ["sales-example@inbound-mailtrap.io"],
      "cc"             => [],
      "subject"        => "Interested in your consulting services",
      "thread_id"      => THREAD_ID,
      "rfc_message_id" => "<CAO0@mail.gmail.com>",
      "headers"        => { "mime-version" => "1.0", "return-path" => "" },
      "text_body"      => "We're a 40-person team at acme.co with a 5000 EUR budget for 40 hours.",
      "html_body"      => "<p>We're a 40-person team at acme.co.</p>"
    }.merge(overrides)
  end

  def message_received_event(overrides = {})
    {
      "event"      => "inbound.message_received",
      "event_id"   => "de1b5a49-8beb-11f1-8053-0a58a9feac02",
      "timestamp"  => 1_785_398_058_498,
      "inbox_id"   => INBOX_ID,
      "message_id" => MESSAGE_ID,
      "from"       => "Sam Prospect <sam@acme.co>"
    }.merge(overrides)
  end

  def webhook_body(events = [message_received_event])
    { "events" => events }.to_json
  end

  def signature_for(body, secret: SECRET)
    OpenSSL::HMAC.hexdigest("SHA256", secret, body)
  end

  def signed_headers(body, secret: SECRET)
    {
      "Content-Type"       => "application/json",
      "Mailtrap-Signature" => signature_for(body, secret: secret)
    }
  end

  def normalized_message(overrides = {})
    Inbound::MessageNormalizer.new(inbound_message(overrides)).call
  end

  # A LeadQualifier::Result without touching Anthropic.
  def qualification(overrides = {})
    defaults = {
      extracted_data: {},
      reply_subject:  "Re: Interested in your consulting services",
      reply_text:     "Could you share your budget and team size?\n\nMelissa",
      reply_html:     "<p>Could you share your budget and team size?</p><p>Melissa</p>",
      hostile:        false,
      off_topic:      false,
      reasoning:      "Partial data supplied.",
      fallback:       false
    }
    LeadQualifier::Result.new(**defaults.merge(overrides))
  end

  def complete_extracted_data
    {
      "company"    => "Acme",
      "website"    => "https://acme.co",
      "employees"  => 40,
      "budget_eur" => 5000,
      "hours"      => 40
    }
  end

  # ENV is process-global; anything set here is undone after each example.
  def set_env(vars)
    @original_env ||= {}
    vars.each do |key, value|
      @original_env[key] = ENV[key] unless @original_env.key?(key)
      ENV[key] = value
    end
  end

  def restore_env
    (@original_env || {}).each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
    @original_env = nil
  end
end
