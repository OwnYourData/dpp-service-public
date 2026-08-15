# frozen_string_literal: true

class CreateDppVersions < ActiveRecord::Migration[7.1]
  def change
    # prEN 18221 (Module 6) — archived snapshots of each DPP change.
    create_table :dpp_versions do |t|
      t.string :dpp_id, null: false
      t.string :product_id, null: false # denormalised: versions outlive the DPP row
      t.integer :version_number, null: false
      t.string :dpp_status
      t.json :content, null: false, default: {}
      t.datetime :archived_at, null: false

      t.timestamps
    end

    add_index :dpp_versions, %i[dpp_id version_number], unique: true
    add_index :dpp_versions, %i[product_id archived_at]
    add_index :dpp_versions, :archived_at
  end
end
