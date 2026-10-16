# frozen_string_literal: true

# Access policies (AccessPolicy) an economic operator has registered, one per
# product type, and the one a passport is classified by.
#
# A registered policy never changes: a new version of a product type's policy
# is registered under a new id. The pair (owner, id) is unique, so two
# operators can use the same id without meeting. The digest is taken over the
# document with sorted keys and rules, and decides whether a second
# registration under the same id is the same policy or a different one.
#
# The reference on the passport is a column of this service, never an
# attribute of the passport (EN 18223:2026 Table 1). NULL for a passport that
# was created without a policy, which is every passport created before this.
class CreateAccessPolicies < ActiveRecord::Migration[7.2]
  def change
    create_table :access_policies do |t|
      t.string :owner_did
      t.string :policy_id, null: false
      t.json   :document, null: false
      t.string :digest, null: false
      t.timestamps
    end
    add_index :access_policies, %i[owner_did policy_id], unique: true

    add_reference :dpps, :access_policy, foreign_key: true, type: :bigint
  end
end
