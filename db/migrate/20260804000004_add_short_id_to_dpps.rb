# frozen_string_literal: true

# Short, resolvable Unique Product Identifier (UPI) for the EU DPP Registry.
# The Registry requires the UPI to be an https URL that resolves with a direct
# 200 (no redirects). A did:oyd is neither, so each DPP gets a short id that can
# be used in a short-link URL
# (https://r.oydapp.eu/p/<short_id>) served by the ResolverController.
class AddShortIdToDpps < ActiveRecord::Migration[7.1]
  def change
    add_column :dpps, :short_id, :string
    add_index :dpps, :short_id, unique: true
  end
end
