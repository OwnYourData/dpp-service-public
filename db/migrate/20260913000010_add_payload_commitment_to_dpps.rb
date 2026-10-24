# frozen_string_literal: true

# Payload commitment (EN 18246:2026, docs/Integrity.md section 6).
#
# A passport identifier is the hash over its DID document, so the *place* it is
# served from is cryptographically bound: no custodian can be substituted
# silently. Its *content* is not bound, until a hash of the delivered payload is
# written into that document. These three columns are what the service needs to
# do that and to say whether it is done:
#
#   payload_hash      hash of the payload as the custodian delivers it, taken at
#                     the last write
#   did_head          identifier of the newest DID document. An update mints a
#                     new one, while dpp_id stays the identifier the carrier
#                     bears and the registry holds; a resolver replays the log
#                     from dpp_id and reports the head as canonicalId
#   did_commit_state  committed | pending | stale. Section 6: a write is not
#                     refused while a commitment is outstanding, so the state has
#                     to be visible instead of silent
class AddPayloadCommitmentToDpps < ActiveRecord::Migration[7.1]
  def change
    add_column :dpps, :payload_hash, :string
    add_column :dpps, :did_head, :string
    add_column :dpps, :did_commit_state, :string
    add_index :dpps, :did_commit_state
  end
end
