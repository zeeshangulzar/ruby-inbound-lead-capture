class AddInboundMessageTrackingToLeads < ActiveRecord::Migration[7.2]
  def change
    # Needed to reply: the Inbound reply endpoint is addressed by
    # inbox_id + message_id, so both travel with the lead.
    add_column :leads, :inbox_id, :integer

    # Mailtrap retries a failed webhook delivery up to 10 times over 24 hours.
    # Recording the last message we processed makes redelivery a no-op instead
    # of a second AI call and a duplicate reply.
    add_column :leads, :last_message_id, :string

    add_index :leads, :last_message_id
  end
end
