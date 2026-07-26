class Lead < ApplicationRecord
  STATUS_IN_CONVERSATION = "in_conversation".freeze
  STATUS_FINALIZED       = "finalized".freeze
  STATUS_RED_FLAGGED     = "red_flagged".freeze

  TIER_RED_FLAG  = "red_flag".freeze
  TIER_FORWARDED = "forwarded".freeze
  TIER_HOT       = "hot".freeze
  TIER_WARM      = "warm".freeze
  TIER_COLD      = "cold".freeze

  REQUIRED_FIELDS  = %w[employees budget_eur hours website].freeze
  MAX_AI_REPLIES   = 5

  validates :thread_id,    presence: true, uniqueness: true
  validates :sender_email, presence: true
  validates :status,       inclusion: { in: [STATUS_IN_CONVERSATION, STATUS_FINALIZED, STATUS_RED_FLAGGED] }

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

  def tier
    verdict&.dig("tier")
  end

  def score
    verdict&.dig("score")
  end
end
