# Sends Melissa's replies through the Mailtrap Inbound reply endpoint.
#
# Replying on the original message — rather than composing a fresh send —
# means Mailtrap sets In-Reply-To / References itself, so the exchange stays
# one conversation both in the prospect's mailbox and in the Mailtrap
# dashboard. There is no need to track threading headers by hand.
#
# @see https://docs.mailtrap.io/developers/inbound/messages
class MelissaMailer
  def initialize(lead:, ai_content:, api_client: nil)
    @lead       = lead
    @ai_content = ai_content
    @api_client = api_client
  end

  def send_follow_up
    Rails.logger.info("[MelissaMailer] follow-up on thread #{@lead.thread_id}")
    deliver(text: @ai_content.reply_text, html: @ai_content.reply_html)
  end

  def send_qualified(scheduling_link:)
    text = <<~TEXT
      Thanks — your enquiry looks like a great fit for us.

      Grab a slot on my calendar and we'll take it from there:
      #{scheduling_link}

      Melissa
    TEXT
    html = <<~HTML
      <p>Thanks — your enquiry looks like a great fit for us.</p>
      <p>Grab a slot on my calendar and we'll take it from there:<br>
      <a href="#{scheduling_link}">#{scheduling_link}</a></p>
      <p>Melissa</p>
    HTML

    deliver(text: text, html: html)
  end

  def send_forwarded(partner_email:)
    text = <<~TEXT
      Thanks for the note. Based on what you've shared, my colleagues at
      #{partner_email} are a better fit — I've put them in copy so they can
      pick things up from here.

      Melissa
    TEXT
    html = <<~HTML
      <p>Thanks for the note. Based on what you've shared, my colleagues at
      <a href="mailto:#{partner_email}">#{partner_email}</a> are a better fit —
      I've put them in copy so they can pick things up from here.</p>
      <p>Melissa</p>
    HTML

    deliver(text: text, html: html, cc: [partner_email])
  end

  private

  def deliver(text:, html:, cc: [])
    unless repliable?
      Rails.logger.error("[MelissaMailer] cannot reply to lead #{@lead.id}: missing inbox_id / last_message_id")
      return
    end

    api_client.reply(
      inbox_id:   @lead.inbox_id,
      message_id: @lead.last_message_id,
      text:       text,
      html:       html,
      cc:         cc,
      from:       sender_address,
      category:   "inbound-lead"
    )
  rescue StandardError => e
    Rails.logger.error("[MelissaMailer] reply failed for thread #{@lead.thread_id}: #{e.class} — #{e.message}")
  end

  def repliable?
    @lead.inbox_id.present? && @lead.last_message_id.present?
  end

  # Mailtrap-hosted inboxes always send from their own address and reject an
  # explicit `from`. Only set it when a custom-domain sender is configured.
  def sender_address
    ENV["MELISSA_EMAIL"].presence
  end

  def api_client
    @api_client ||= Inbound::ApiClient.new
  end
end
