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

ActiveRecord::Schema[7.2].define(version: 2026_10_24_000021) do
  create_table "access_event_parties", force: :cascade do |t|
    t.bigint "access_event_id", null: false
    t.string "did", null: false
    t.string "relation", null: false
    t.index ["access_event_id"], name: "index_access_event_parties_on_access_event_id"
    t.index ["did", "access_event_id"], name: "index_access_event_parties_on_did_and_access_event_id"
  end

  create_table "access_events", force: :cascade do |t|
    t.datetime "occurred_at", null: false
    t.string "event", null: false
    t.string "dpp_id"
    t.string "owner_did"
    t.string "reader_did"
    t.json "roles"
    t.string "basis"
    t.json "grants"
    t.string "operation"
    t.datetime "version_date"
    t.integer "status"
    t.string "reason"
    t.string "custodian"
    t.string "pod_object_id"
    t.string "pod_path"
    t.string "controlled_digest"
    t.string "request_id"
    t.json "details"
    t.datetime "created_at", null: false
    t.index ["dpp_id", "occurred_at"], name: "index_access_events_on_dpp_id_and_occurred_at"
    t.index ["occurred_at"], name: "index_access_events_on_occurred_at"
  end

  create_table "access_grants", force: :cascade do |t|
    t.string "issuer_did", null: false
    t.string "jti", null: false
    t.string "subject_did", null: false
    t.json "roles", null: false
    t.string "scope", null: false
    t.json "dpp_ids"
    t.string "purpose"
    t.datetime "not_before", null: false
    t.datetime "expires_at", null: false
    t.text "token", null: false
    t.string "digest", null: false
    t.datetime "revoked_at"
    t.string "revoked_by"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.string "revocation_reason"
    t.index ["issuer_did", "jti"], name: "index_access_grants_on_issuer_did_and_jti", unique: true
    t.index ["subject_did"], name: "index_access_grants_on_subject_did"
  end

  create_table "access_policies", force: :cascade do |t|
    t.string "owner_did"
    t.string "policy_id", null: false
    t.json "document", null: false
    t.string "digest", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["owner_did", "policy_id"], name: "index_access_policies_on_owner_did_and_policy_id", unique: true
  end

  create_table "dpp_versions", force: :cascade do |t|
    t.string "dpp_id", null: false
    t.string "product_id", null: false
    t.integer "version_number", null: false
    t.string "dpp_status"
    t.json "content", default: {}, null: false
    t.datetime "archived_at", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.bigint "access_policy_id"
    t.string "owner_did"
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
    t.string "payload_hash"
    t.string "did_head"
    t.string "did_commit_state"
    t.datetime "payload_checked_at"
    t.string "product_host"
    t.date "retain_until"
    t.bigint "access_policy_id"
    t.string "storage_controlled_object_id"
    t.json "controlled_content"
    t.text "signature_jws"
    t.string "signature_state"
    t.datetime "signature_checked_at"
    t.index ["access_policy_id"], name: "index_dpps_on_access_policy_id"
    t.index ["did_commit_state"], name: "index_dpps_on_did_commit_state"
    t.index ["dpp_id"], name: "index_dpps_on_dpp_id", unique: true
    t.index ["owner_did"], name: "index_dpps_on_owner_did"
    t.index ["product_id", "dpp_status"], name: "index_dpps_on_product_id_and_dpp_status"
    t.index ["product_id"], name: "index_dpps_on_product_id"
    t.index ["product_key", "product_host"], name: "index_dpps_on_active_product", unique: true, where: "dpp_status = 'Active'"
    t.index ["product_key"], name: "index_dpps_on_product_key"
    t.index ["storage_backend"], name: "index_dpps_on_storage_backend"
  end

  create_table "rate_counters", force: :cascade do |t|
    t.string "bucket", null: false
    t.integer "hits", default: 0, null: false
    t.bigint "window_ends_at", null: false
    t.index ["bucket"], name: "index_rate_counters_on_bucket", unique: true
    t.index ["window_ends_at"], name: "index_rate_counters_on_window_ends_at"
  end

  create_table "token_uses", force: :cascade do |t|
    t.string "issuer", null: false
    t.string "jti", null: false
    t.bigint "expires_at", null: false
    t.index ["expires_at"], name: "index_token_uses_on_expires_at"
    t.index ["issuer", "jti"], name: "index_token_uses_on_issuer_and_jti", unique: true
  end

  add_foreign_key "access_event_parties", "access_events"
  add_foreign_key "dpps", "access_policies"
end
