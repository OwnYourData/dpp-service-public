# frozen_string_literal: true

# Variante A (EN 18219:2026 / did:oyd): when the DPP Service mints the DID itself
# it must keep the DID's private keys to update/revoke it later. They are stored
# encrypted at rest (KeyVault, AES-256-GCM). did_managed distinguishes a
# service-minted DID (Variante A) from a client-supplied one (Variante C).
class AddDidKeysToDpps < ActiveRecord::Migration[7.1]
  def change
    add_column :dpps, :did_managed, :boolean, null: false, default: false
    add_column :dpps, :did_doc_key_enc, :text # encrypted OYDID doc private key
    add_column :dpps, :did_rev_key_enc, :text # encrypted OYDID revocation key
    add_column :dpps, :did_rev_log_enc, :text # encrypted OYDID revocation log
  end
end
