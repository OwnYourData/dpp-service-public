# frozen_string_literal: true

# The bearer tokens this service has accepted (TokenUse), by issuer and jti,
# for as long as each token is valid: a token is accepted once. Nothing of the
# token itself is kept, and rows of expired tokens are pruned as new ones come
# in.
class CreateTokenUses < ActiveRecord::Migration[7.2]
  def change
    create_table :token_uses do |t|
      t.string :issuer, null: false
      t.string :jti, null: false
      t.bigint :expires_at, null: false
    end
    add_index :token_uses, %i[issuer jti], unique: true
    add_index :token_uses, :expires_at
  end
end
