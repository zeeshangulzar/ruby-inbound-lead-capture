# Pushes qualified leads to HubSpot as a Contact. Env-gated on HUBSPOT_API_KEY
# — if the key is not set, the sync is skipped silently. If HubSpot errors out,
# the failure is logged and the caller continues (fail-open).
class HubspotSync
  def initialize(lead:)
    @lead = lead
  end

  def call
    return nil if api_key.blank?

    client   = Hubspot::Client.new(access_token: api_key)
    contact  = client.crm.contacts.basic_api.create(body: { properties: contact_properties })
    contact.id
  rescue => e
    Rails.logger.error("[HubspotSync] failed for lead #{@lead.id}: #{e.class} — #{e.message}")
    nil
  end

  private

  def api_key
    ENV["HUBSPOT_API_KEY"].to_s
  end

  def contact_properties
    data      = @lead.extracted_data
    first, last = split_name(@lead.sender_name)

    {
      email:          @lead.sender_email,
      firstname:      first,
      lastname:       last,
      company:        data["company"],
      website:        data["website"],
      # `numemployees` is the contact property — `numberofemployees` belongs to
      # the company object. It is also a dropdown, not a number, so the count
      # has to be mapped to one of its buckets.
      numemployees:   employee_bucket(data["employees"]),
      hs_lead_status: "NEW"
    }.compact
  end

  # HubSpot's contact `numemployees` property is an enumeration. Sending a raw
  # count fails the whole create with
  # "40 was not one of the allowed options: [1-5, 5-25, ...]".
  EMPLOYEE_BUCKETS = [
    [5,    "1-5"],
    [25,   "5-25"],
    [50,   "25-50"],
    [100,  "50-100"],
    [500,  "100-500"],
    [1000, "500-1000"]
  ].freeze
  LARGEST_EMPLOYEE_BUCKET = "1000+".freeze

  def employee_bucket(count)
    number = Integer(count)
    return nil if number.negative?

    _, bucket = EMPLOYEE_BUCKETS.find { |ceiling, _| number <= ceiling }
    bucket || LARGEST_EMPLOYEE_BUCKET
  rescue ArgumentError, TypeError
    nil
  end

  def split_name(full_name)
    return [nil, nil] if full_name.blank?

    parts = full_name.strip.split(/\s+/, 2)
    [parts[0], parts[1]]
  end
end
