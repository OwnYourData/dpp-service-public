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

ActiveRecord::Schema[7.2].define(version: 2026_08_25_000009) do
  create_table "dpp_versions", force: :cascade do |t|
    t.string "dpp_id", null: false
    t.string "product_id", null: false
    t.integer "version_number", null: false
    t.string "dpp_status"
    t.json "content", default: {}, null: false
    t.datetime "archived_at", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["archived_at"], name: "index_dpp_versions_on_archived_at"
    t.index ["dpp_id", "version_number"], name: "index_dpp_versions_on_dpp_id_and_version_number", unique: true
    t.index ["product_id", "archived_at"], name: "index_dpp_versions_on_product_id_and_archived_at"
  end

  create_table "dpps", id: false, force: :cascade do |t|
    t.string "dpp_id", null: false
    t.string "product_id", null: false
    t.string "granularity", default: "item", null: false
    t.string "dpp_schema_version", null: false
    t.string "dpp_status", default: "Active", null: false
    t.string "economic_operator_id", null: false
    t.string "facility_id"
    t.datetime "last_update", null: false
    t.json "content", default: {}, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.boolean "did_managed", default: false, null: false
    t.text "did_doc_key_enc"
    t.text "did_rev_key_enc"
    t.text "did_rev_log_enc"
    t.string "storage_backend", default: "local", null: false
    t.string "storage_base_url"
    t.string "storage_collection_id"
    t.string "storage_object_id"
    t.string "owner_did"
    t.text "storage_delegation"
    t.string "product_key"
    t.index ["dpp_id"], name: "index_dpps_on_dpp_id", unique: true
    t.index ["owner_did"], name: "index_dpps_on_owner_did"
    t.index ["product_id", "dpp_status"], name: "index_dpps_on_product_id_and_dpp_status"
    t.index ["product_id"], name: "index_dpps_on_product_id"
    t.index ["product_key"], name: "index_dpps_on_product_key"
    t.index ["storage_backend"], name: "index_dpps_on_storage_backend"
  end
end
