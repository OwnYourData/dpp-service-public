# frozen_string_literal: true

# A passport this service holds itself and that has an access policy is kept
# as a public and a controlled part, like a passport at a custodian that holds
# controlled cards (PassportSplit): +content+ is the public part naming the
# controlled one in ControlledData, +controlled_content+ the controlled part
# with its salt. NULL for a passport without a policy, whose +content+ stays
# the whole passport.
#
# Archived versions remember the policy and the owner of the passport they were
# taken from, so they can still be read per role after the passport itself has
# been deleted.
class AddControlledContentToDpps < ActiveRecord::Migration[7.2]
  def change
    add_column :dpps, :controlled_content, :json
    add_column :dpp_versions, :access_policy_id, :bigint
    add_column :dpp_versions, :owner_did, :string
  end
end
