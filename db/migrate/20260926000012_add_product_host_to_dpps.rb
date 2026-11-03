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
#
# The existing rows are filled in with SQL and plain URI parsing, not through
# the model: a migration runs against the schema of its own day, and the model
# of today expects the schema of today.
class AddProductHostToDpps < ActiveRecord::Migration[7.2]
  INDEX = "index_dpps_on_active_product"

  def up
    add_column :dpps, :product_host, :string

    select_rows("SELECT dpp_id, product_id FROM dpps WHERE product_id IS NOT NULL").each do |dpp_id, product_id|
      host = host_of(product_id)
      next if host.nil?

      execute("UPDATE dpps SET product_host = #{connection.quote(host.downcase)} " \
              "WHERE dpp_id = #{connection.quote(dpp_id)}")
    end

    add_index :dpps, %i[product_key product_host], unique: true,
                                                   where: "dpp_status = 'Active'",
                                                   name: INDEX
  end

  def down
    remove_index  :dpps, name: INDEX
    remove_column :dpps, :product_host
  end

  private

  # The host of a product identifier, as ProductIdentifier#host reads it.
  def host_of(product_id)
    URI.parse(product_id.to_s.strip).host
  rescue URI::InvalidURIError
    nil
  end
end
