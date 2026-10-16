# frozen_string_literal: true

# One product, one active passport (EN 18219:2026 3.1.25), now held by the
# database too. DppsController#create checks before it writes, so two
# concurrent creates for the same product could both pass that check; the
# unique index lets only one of them through.
#
# A product is identified by its whole identifier. The path (product_key) is
# not enough: the host belongs to the economic operator, and the same path
# under another host is another operator's product. Hosts compare without
# regard to case, as DNS does, so the host is stored lower-cased.
#
# Partial, over active passports only: DeleteDPPById marks the row archived
# before it removes it. Passports minted before the carrier redesign have no
# product_key, and NULLs never collide in a unique index.
class AddProductHostToDpps < ActiveRecord::Migration[7.2]
  INDEX = "index_dpps_on_active_product"

  def up
    add_column :dpps, :product_host, :string

    Dpp.reset_column_information
    Dpp.find_each do |dpp|
      host = ProductIdentifier.new(dpp.product_id).host
      dpp.update_column(:product_host, host.downcase) if host
    end

    add_index :dpps, %i[product_key product_host], unique: true,
                                                   where: "dpp_status = 'Active'",
                                                   name: INDEX
  end

  def down
    remove_index  :dpps, name: INDEX
    remove_column :dpps, :product_host
  end
end
