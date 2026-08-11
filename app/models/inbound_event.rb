class InboundEvent < ApplicationRecord
  STATUS_QUEUED    = "queued".freeze
  STATUS_PROCESSED = "processed".freeze
  STATUS_SKIPPED   = "skipped".freeze
  STATUS_FAILED    = "failed".freeze

  ALL_STATUSES = [STATUS_QUEUED, STATUS_PROCESSED, STATUS_SKIPPED, STATUS_FAILED].freeze

  validates :event_id,   presence: true, uniqueness: true
  validates :message_id, presence: true, uniqueness: true
  validates :status,     inclusion: { in: ALL_STATUSES }

  def mark_processed!
    update!(status: STATUS_PROCESSED, processed_at: Time.current, last_error: nil)
  end

  def mark_skipped!(reason)
    update!(status: STATUS_SKIPPED, processed_at: Time.current, last_error: reason.to_s.presence)
  end

  def mark_failed!(error)
    update!(status: STATUS_FAILED, last_error: "#{error.class}: #{error.message}".truncate(1000))
  end
end
