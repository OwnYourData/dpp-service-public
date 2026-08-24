# frozen_string_literal: true

# Removes the opaque short link.
#
# It was the carrier form of the design this one replaced: a twelve-character
# path under a host of ours, resolved by ResolverController. Since the carrier
# now bears the ProductID itself (EN 18219 cl. 3.22, 4.5.2 (1)) nothing issues
# it any more, and no carrier bearing one was ever printed -- so there is
# nothing to keep resolving, and keeping the column would only carry a
# superseded design into every archive of this repository.
class DropShortIdFromDpps < ActiveRecord::Migration[7.2]
  def up
    remove_index :dpps, :short_id, if_exists: true
    remove_column :dpps, :short_id, if_exists: true
  end

  def down
    add_column :dpps, :short_id, :string
    add_index :dpps, :short_id, unique: true
  end
end
