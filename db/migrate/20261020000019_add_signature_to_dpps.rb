# frozen_string_literal: true

# The signature of the economic operator over the public part of a passport
# (docs/Integrity.md section 10): the compact JWS as it was submitted, the state
# it is in (pending, signed, stale; NULL for a passport that was never signed)
# and when its key was last checked. Columns of this service, never part of the
# passport: EN 18223:2026 Table 1 has no attribute for a signature.
class AddSignatureToDpps < ActiveRecord::Migration[7.2]
  def change
    add_column :dpps, :signature_jws, :text
    add_column :dpps, :signature_state, :string
    add_column :dpps, :signature_checked_at, :datetime
  end
end
