# Sends Melissa's outbound replies via the Mailtrap Email Sending API.
# Every reply carries the threading headers (In-Reply-To, References, X-Thread-Id)
# so the exchange appears as one conversation in the prospect's mailbox and in
# the Mailtrap dashboard.
class MelissaMailer
  def initialize(lead:, ai_content:)
    @lead       = lead
    @ai_content = ai_content
  end

  def send_follow_up
    subject = @ai_content.reply_subject.presence || "Re: #{@lead.last_subject}"
    send_mail(subject: subject, text: @ai_content.reply_text, html: @ai_content.reply_html)
  end

  def send_qualified(scheduling_link:)
    subject = "Re: #{@lead.last_subject.presence || 'your enquiry'}"
    text    = <<~TEXT
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

    send_mail(subject: subject, text: text, html: html)
  end

  def send_forwarded(partner_email:)
    subject = "Re: #{@lead.last_subject.presence || 'your enquiry'}"
    text    = <<~TEXT
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

    send_mail(subject: subject, text: text, html: html, cc: [partner_email])
  end

  private

  def send_mail(subject:, text:, html:, cc: [])
    mail = Mailtrap::Mail::Base.new(
      from:    { email: ENV.fetch("MELISSA_EMAIL", "melissa@example.com"), name: "Melissa" },
      to:      [{ email: @lead.sender_email, name: @lead.sender_name.presence || @lead.sender_email }],
      cc:      cc.map { |addr| { email: addr } },
      subject: subject,
      text:    text,
      html:    html,
      headers: threading_headers,
      category: "inbound-lead"
    )

    Mailtrap::Client.new(api_key: ENV.fetch("MAILTRAP_API_TOKEN")).send(mail)
  rescue => e
    Rails.logger.error("[MelissaMailer] send failed for thread #{@lead.thread_id}: #{e.class} — #{e.message}")
  end

  def threading_headers
    {
      "In-Reply-To" => @lead.thread_id,
      "References"  => @lead.thread_id,
      "X-Thread-Id" => @lead.thread_id
    }
  end
end
