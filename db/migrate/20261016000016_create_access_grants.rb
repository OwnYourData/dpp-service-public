# frozen_string_literal: true

# Access grants (AccessGrant): signed statements that a reader DID may read the
# controlled part of passports in one or more access classes. An economic
# operator grants legitimateInterest for its own passports; an issuer on the
# list of authority issuers (AuthorityIssuers) grants authority.
#
# The signed statement itself is kept as it was presented: it is the evidence
# of who granted what, and it holds no secret. A grant is never deleted, only
# revoked, so an access read under it stays traceable to it.
class CreateAccessGrants < ActiveRecord::Migration[7.2]
  def change
    create_table :access_grants do |t|
      t.string   :issuer_did, null: false
      t.string   :jti, null: false
      t.string   :subject_did, null: false
      t.json     :roles, null: false
      t.string   :scope, null: false
      t.json     :dpp_ids
      t.string   :purpose
      t.datetime :not_before, null: false
      t.datetime :expires_at, null: false
      t.text     :token, null: false
      t.string   :digest, null: false
      t.datetime :revoked_at
      t.string   :revoked_by
      t.timestamps
    end
    add_index :access_grants, %i[issuer_did jti], unique: true
    add_index :access_grants, :subject_did
  end
end
