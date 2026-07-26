# This file is auto-generated from the current state of the database. Instead
# of editing this file, please use the migrations feature of Active Record to
# incrementally modify your database, and then regenerate this schema definition.
#
# This file is the source Rails uses to define your schema when running `bin/rails
# db:schema:load`. When creating a new database, `bin/rails db:schema:load` tends to
# be faster and is potentially less error prone than running all of your
# migrations from scratch. Old migrations may fail to apply correctly if those
# migrations use external dependencies or application code.
#
# It's strongly recommended that you check this file into your version control system.

ActiveRecord::Schema[7.2].define(version: 2026_07_26_100000) do
  create_table "leads", force: :cascade do |t|
    t.string "thread_id", null: false
    t.string "sender_email", null: false
    t.string "sender_name"
    t.string "last_subject"
    t.integer "ai_reply_count", default: 0, null: false
    t.json "extracted_data", default: {}, null: false
    t.json "verdict"
    t.string "status", default: "in_conversation", null: false
    t.string "hubspot_contact_id"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["sender_email"], name: "index_leads_on_sender_email"
    t.index ["status"], name: "index_leads_on_status"
    t.index ["thread_id"], name: "index_leads_on_thread_id", unique: true
  end
end
