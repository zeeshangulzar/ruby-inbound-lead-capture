class CreateInboundEvents < ActiveRecord::Migration[7.2]
  def change
    create_table :inbound_events do |t|
      t.string   :event_id,     null: false
      t.string   :message_id,   null: false
      t.integer  :inbox_id
      t.string   :status,       null: false, default: "queued"
      t.json     :payload
      t.datetime :processed_at
      t.text     :last_error

      t.timestamps
    end

    # event_id is the natural idempotency key on the webhook envelope; message_id
    # is the natural idempotency key on the actual email. Enforcing both at the
    # database means a redelivery or an out-of-order duplicate cannot slip past
    # the application check.
    add_index :inbound_events, :event_id,   unique: true
    add_index :inbound_events, :message_id, unique: true
    add_index :inbound_events, :status
  end
end
