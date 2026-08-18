# frozen_string_literal: true

# Records which DID created a passport, so writes can be restricted to it
# (prEN 18239: access rights). Only meaningful together with verified tokens —
# see DidTokenVerifier and DPP_AUTH_MODE.
#
# Deliberately a separate column and not EconomicOperatorID: that field is part
# of the document and under the client's control, while this one is set by the
# service from the verified token and never from the payload.
class AddOwnerDidToDpps < ActiveRecord::Migration[7.1]
  def change
    add_column :dpps, :owner_did, :string
    add_index  :dpps, :owner_did
  end
end
