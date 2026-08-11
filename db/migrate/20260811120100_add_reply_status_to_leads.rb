class AddReplyStatusToLeads < ActiveRecord::Migration[7.2]
  def change
    # Tracks the outcome of the most recent outbound reply. Counting only sent
    # replies against the 5-reply cap, and only flipping status to `finalized`
    # after a successful send, depends on having this recorded separately from
    # ai_reply_count.
    add_column :leads, :last_reply_status, :string
    add_column :leads, :last_reply_error,  :text
  end
end
