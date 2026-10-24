# frozen_string_literal: true

# The signature of the economic operator over an archived version
# (docs/Integrity.md section 10) and what it signed: the compact JWS accepted
# for the version, and the public part of the version as readers without
# access rights got it then. ReadDPPVersionByIdAndDate delivers the public part
# kept here while the passport's access policy is the one the version had,
# and the signature where its payload is exactly that answer.
class AddSignatureToDppVersions < ActiveRecord::Migration[7.2]
  def change
    add_column :dpp_versions, :signature_jws, :text
    add_column :dpp_versions, :published_content, :json
  end
end
