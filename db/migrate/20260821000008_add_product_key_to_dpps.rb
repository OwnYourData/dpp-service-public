# frozen_string_literal: true

# The host-independent part of the ProductID (the GS1 Digital Link path), used
# as the lookup key so that one custodian store can serve any number of
# operator-owned hostnames pointed at it by CNAME.
#
# Nullable on purpose: passports created before the carrier redesign carry an
# opaque short link and a ProductID that is not a Digital Link. They keep
# resolving through /p/:short_id, and their product_key stays empty.
#
# The existing rows are filled in with SQL, not through the model: a migration
# runs against the schema of its own day, and the model of today expects the
# schema of today. ProductIdentifier reads nothing but the identifier.
class AddProductKeyToDpps < ActiveRecord::Migration[7.2]
  def up
    add_column :dpps, :product_key, :string
    add_index  :dpps, :product_key

    select_rows("SELECT dpp_id, product_id FROM dpps WHERE product_id IS NOT NULL").each do |dpp_id, product_id|
      key = ProductIdentifier.new(product_id).product_key
      next if key.nil?

      execute("UPDATE dpps SET product_key = #{connection.quote(key)} " \
              "WHERE dpp_id = #{connection.quote(dpp_id)}")
    end
  end

  def down
    remove_index  :dpps, :product_key
    remove_column :dpps, :product_key
  end
end
