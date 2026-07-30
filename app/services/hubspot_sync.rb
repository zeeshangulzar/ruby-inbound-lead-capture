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
      email:            @lead.sender_email,
      firstname:        first,
      lastname:         last,
      company:          data["company"],
      website:          data["website"],
      # HubSpot's built-in employee-count property is `numberofemployees`;
      # an unknown property name makes the whole create fail with a 400.
      numberofemployees: data["employees"],
      hs_lead_status:   "NEW"
    }.compact
  end

  def split_name(full_name)
    return [nil, nil] if full_name.blank?

    parts = full_name.strip.split(/\s+/, 2)
    [parts[0], parts[1]]
  end
end
