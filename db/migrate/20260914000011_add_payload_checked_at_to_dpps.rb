# frozen_string_literal: true

# When the holder keeps the document key, the service cannot write the payload
# commitment — it can only report the expected hash and wait. The state therefore
# has to be able to change without a write, and the read paths are where that
# happens (docs/Integrity.md section 6).
#
# Re-resolving a DID costs a second or two, so a passport is re-checked at most
# once per DPP_COMMIT_RECHECK_INTERVAL. This column is what makes that possible:
# without it, every read of a `pending` passport would resolve again, and a
# crawler would decide how much work the service does.
class AddPayloadCheckedAtToDpps < ActiveRecord::Migration[7.1]
  def change
    add_column :dpps, :payload_checked_at, :datetime
  end
end
