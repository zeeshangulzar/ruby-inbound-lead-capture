# Sends Melissa's replies through the Mailtrap Inbound reply endpoint.
#
# Replying on the original message — rather than composing a fresh send —
# means Mailtrap sets In-Reply-To / References itself, so the exchange stays
# one conversation both in the prospect's mailbox and in the Mailtrap
# dashboard. There is no need to track threading headers by hand.
#
# The email bodies are rendered from ERB partials under app/views/melissa/, so
# escaping is handled by Rails rather than by whatever the LLM chooses to
# return in a JSON field. The caller receives a Result telling it whether the
# reply landed, so successful sends can gate `ai_reply_count` increments and
# terminal statuses without the previous best-effort accounting.
#
# @see https://docs.mailtrap.io/developers/inbound/messages
class MelissaMailer
  Result = Struct.new(:status, :error, keyword_init: true) do
    def sent?
      status == :sent
    end

    def failed?
      status == :failed
    end
  end

  def initialize(lead:, api_client: nil)
    @lead       = lead
    @api_client = api_client
  end

  def send_follow_up(reply_paragraphs:)
    return failure("reply_paragraphs is empty") if reply_paragraphs.blank?

    deliver(
      text: render(:text, "follow_up", paragraphs: reply_paragraphs),
      html: render(:html, "follow_up", paragraphs: reply_paragraphs)
    )
  end

  def send_qualified(scheduling_link:)
    deliver(
      text: render(:text, "qualified", scheduling_link: scheduling_link),
      html: render(:html, "qualified", scheduling_link: scheduling_link)
    )
  end

  def send_forwarded(partner_email:)
    deliver(
      text: render(:text, "forwarded", partner_email: partner_email),
      html: render(:html, "forwarded", partner_email: partner_email),
      cc:   [partner_email]
    )
  end

  private

  def render(format, template, **locals)
    ApplicationController.render(
      template: "melissa/#{template}",
      formats:  [format],
      layout:   false,
      locals:   locals
    )
  end

  def deliver(text:, html:, cc: [])
    return failure("missing inbox_id / last_message_id") unless repliable?

    api_client.reply(
      inbox_id:   @lead.inbox_id,
      message_id: @lead.last_message_id,
      text:       text,
      html:       html,
      cc:         deliverable_cc(cc),
      from:       sender_address,
      category:   "inbound-lead"
    )
    Rails.logger.info("[MelissaMailer] sent reply on thread #{@lead.thread_id}")
    Result.new(status: :sent, error: nil)
  rescue StandardError => e
    Rails.logger.error("[MelissaMailer] reply failed for thread #{@lead.thread_id}: #{e.class} — #{e.message}")
    failure("#{e.class}: #{e.message}")
  end

  def failure(reason)
    Rails.logger.error("[MelissaMailer] cannot reply to lead #{@lead.id}: #{reason}")
    Result.new(status: :failed, error: reason)
  end

  # The reply endpoint addresses the original sender itself, and Mailtrap
  # rejects the whole request when an address appears twice ("address ... is
  # not unique in the request"). Drop any CC that is already the recipient —
  # which happens whenever the partner address is also the prospect's.
  def deliverable_cc(cc)
    recipient = @lead.sender_email.to_s.downcase
    Array(cc).compact.reject { |address| address.to_s.downcase == recipient }.uniq
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
