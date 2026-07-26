class CreateLeads < ActiveRecord::Migration[7.2]
  def change
    create_table :leads do |t|
      t.string  :thread_id,          null: false
      t.string  :sender_email,       null: false
      t.string  :sender_name
      t.string  :last_subject
      t.integer :ai_reply_count,     null: false, default: 0
      t.json    :extracted_data,     null: false, default: {}
      t.json    :verdict
      t.string  :status,             null: false, default: "in_conversation"
      t.string  :hubspot_contact_id

      t.timestamps
    end

    add_index :leads, :thread_id, unique: true
    add_index :leads, :sender_email
    add_index :leads, :status
  end
end
