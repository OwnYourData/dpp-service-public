# frozen_string_literal: true

# Who may see an access log entry, and as what: the owner of the passport, the
# reader, or the issuer of an access grant (AccessLog). Added with the entry,
# never changed.
class AccessEventParty < ApplicationRecord
  RELATIONS = %w[owner reader issuer].freeze

  belongs_to :access_event

  validates :did, presence: true
  validates :relation, inclusion: { in: RELATIONS }

  before_destroy { raise AccessEvent::AppendOnly, "the access log is append-only" }

  def readonly? = persisted? || super
end
