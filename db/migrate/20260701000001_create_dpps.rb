# frozen_string_literal: true

class CreateDpps < ActiveRecord::Migration[7.1]
  def change
    # EN 18223:2026 Table 1 — header attributes as columns; full document in :content.
    create_table :dpps, id: false do |t|
      t.string :dpp_id, null: false                       # DigitalProductPassportID
      t.string :product_id, null: false                   # ProductID
      t.string :granularity, null: false, default: "item" # model | batch | item
      t.string :dpp_schema_version, null: false           # DPPSchemaVersion
      t.string :dpp_status, null: false, default: "Active" # Active | Archived
      t.string :economic_operator_id, null: false         # EconomicOperatorID
      t.string :facility_id                               # FacilityID (0..1)
      t.datetime :last_update, null: false                # LastUpdate (UTC)
      t.json :content, null: false, default: {}           # full DPP document

      t.timestamps
    end

    add_index :dpps, :dpp_id, unique: true
    add_index :dpps, :product_id
    add_index :dpps, %i[product_id dpp_status]
  end
end
