# frozen_string_literal: true

# docs/Delegation.md §9 and §13.
#
# The pod credentials go away. Until now a pod-backed passport carried the
# storage JWT — base_url, collection_id, client_id and client_secret —
# encrypted under KEY_VAULT_KEK, which made this service the repository of the
# pod credentials of every economic operator using it.
#
# What replaces it is the delegation the holder signed: it names this service,
# this pod and exactly one product, it expires, and the holder can revoke it at
# the pod on its own. It is stored in the clear on purpose — without the private
# key of the service DID (DPP_SERVICE_DOC_KEY) nobody can redeem it, so there is
# no secret left to protect. After this migration KEY_VAULT_KEK guards the
# passport keys of variant A and nothing else.
#
# No compatibility path (§13): passports created before this cannot be written
# any more, because the credential they relied on is gone. They are deliberately
# left in place rather than deleted here — a migration is the wrong place to
# throw data away silently. PodStorage.for raises a ConfigError naming the
# situation, and such passports have to be created again.
class ReplacePodCredentialsWithDelegation < ActiveRecord::Migration[7.1]
  def change
    add_column :dpps, :storage_delegation, :text

    # Reversible in shape only: rolling back restores an empty column, not the
    # credentials, which is the intended one-way door.
    remove_column :dpps, :storage_credentials_enc, :text
  end
end
