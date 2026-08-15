# frozen_string_literal: true

# Archived snapshot of a DPP (prEN 18221 — data storage, archiving and data
# persistence / Module 6). Enables ReadDPPVersionByProductIdAndDate.
#
# Versions deliberately OUTLIVE their Dpp row: DeleteDPPById removes the active
# passport, but the archived history must remain retrievable (prEN 18222 §4.8
# in conjunction with prEN 18221). Hence the association is optional and
# +product_id+ is stored on the version itself, so lookups need no join.
class DppVersion < ApplicationRecord
  belongs_to :dpp, foreign_key: "dpp_id", primary_key: "dpp_id",
                   inverse_of: :dpp_versions, optional: true

  validates :dpp_id, :product_id, presence: true
  validates :version_number, presence: true, uniqueness: { scope: :dpp_id }
  validates :archived_at, presence: true

  scope :for_product, ->(product_id) { where(product_id: product_id) }
end
