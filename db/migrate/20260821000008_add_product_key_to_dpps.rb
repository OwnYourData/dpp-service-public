# frozen_string_literal: true

# The host-independent part of the ProductID (the GS1 Digital Link path), used
# as the lookup key so that one custodian store can serve any number of
# operator-owned hostnames pointed at it by CNAME.
#
# Nullable on purpose: passports created before the carrier redesign carry an
# opaque short link and a ProductID that is not a Digital Link. They keep
# resolving through /p/:short_id, and their product_key stays empty.
class AddProductKeyToDpps < ActiveRecord::Migration[7.2]
  def up
    add_column :dpps, :product_key, :string
    add_index  :dpps, :product_key

    Dpp.reset_column_information
    Dpp.find_each do |dpp|
      key = ProductIdentifier.new(dpp.product_id).product_key
      dpp.update_column(:product_key, key) if key
    end
  end

  def down
    remove_index  :dpps, :product_key
    remove_column :dpps, :product_key
  end
end
