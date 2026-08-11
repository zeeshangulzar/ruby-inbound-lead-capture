class Lead < ApplicationRecord
  STATUS_IN_CONVERSATION = "in_conversation".freeze
  STATUS_FINALIZED       = "finalized".freeze
  STATUS_RED_FLAGGED     = "red_flagged".freeze

  TIER_RED_FLAG  = "red_flag".freeze
  TIER_FORWARDED = "forwarded".freeze
  TIER_HOT       = "hot".freeze
  TIER_WARM      = "warm".freeze
  TIER_COLD      = "cold".freeze

  REPLY_STATUS_PENDING = "pending".freeze
  REPLY_STATUS_SENT    = "sent".freeze
  REPLY_STATUS_FAILED  = "failed".freeze

  REQUIRED_FIELDS  = %w[employees budget_eur hours website].freeze
  MAX_AI_REPLIES   = 5

  validates :thread_id,    presence: true, uniqueness: true
  validates :sender_email, presence: true
  validates :status,       inclusion: { in: [STATUS_IN_CONVERSATION, STATUS_FINALIZED, STATUS_RED_FLAGGED] }

  # Mailtrap redelivers a webhook until it gets a 2xx, so the same message can
  # arrive several times. Anything already processed must not be run again.
  def already_processed?(message_id)
    last_message_id.present? && last_message_id == message_id.to_s
  end

  def missing_required_fields
    REQUIRED_FIELDS.reject { |field| extracted_data[field].present? }
  end

  def all_required_fields_present?
    missing_required_fields.empty?
  end

  def reply_cap_reached?
    ai_reply_count >= MAX_AI_REPLIES
  end

  def ready_for_final_verdict?
    all_required_fields_present? || reply_cap_reached?
  end

  # Reaching the reply cap means we gave up asking and qualified on whatever the
  # prospect volunteered, so the data is reported as minimal however many fields
  # happen to be filled. Otherwise it reflects how much is still missing.
  def data_completeness
    return "minimal" if reply_cap_reached? && !all_required_fields_present?

    case missing_required_fields.size
    when 0    then "full"
    when 1..2 then "partial"
    else           "minimal"
    end
  end

  def tier
    verdict&.dig("tier")
  end

  def score
    verdict&.dig("score")
  end
end
