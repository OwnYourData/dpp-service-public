# frozen_string_literal: true

# The object id of a passport's controlled card at the custodian
# (DigitalProductPassportControlled, next to the public DigitalProductPassport
# card in the same collection). Set when the card is created, before its
# payload is written, so a write that breaks off halfway leaves the id behind.
# NULL for a passport that is not split: no access policy, a local passport, or
# a custodian that does not hold controlled cards.
class AddStorageControlledObjectIdToDpps < ActiveRecord::Migration[7.2]
  def change
    add_column :dpps, :storage_controlled_object_id, :string
  end
end
