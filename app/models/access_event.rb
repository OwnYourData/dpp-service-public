# frozen_string_literal: true

# One entry of the access log (AccessLog, docs/AccessClasses.md §10). Entries
# are only ever added: a saved entry is read-only, and destroying one is
# refused. Pruning after the retention period (AccessLog.prune!) is the one
# way entries leave, and it is not reachable over the API.
class AccessEvent < ApplicationRecord
  EVENTS = %w[read refused integrityError serviceRead grantRegistered grantRevoked].freeze

  class AppendOnly < StandardError; end

  has_many :parties, class_name: "AccessEventParty", dependent: nil

  validates :event, inclusion: { in: EVENTS }
  validates :occurred_at, presence: true

  before_destroy { raise AppendOnly, "the access log is append-only" }

  def readonly? = persisted? || super

  # The entry as an owner, a reader, an issuer or the operator gets it: no
  # content, no tokens.
  def summary
    custodian_part = { "host" => custodian, "objectId" => pod_object_id }.compact if custodian
    {
      "id" => id.to_s, "at" => occurred_at.utc.iso8601(3), "event" => event, "dppId" => dpp_id,
      "owner" => owner_did, "reader" => reader_did, "roles" => roles.presence, "basis" => basis,
      "grants" => grants.presence, "operation" => operation, "date" => version_date&.utc&.iso8601,
      "status" => status, "reason" => reason, "custodian" => custodian_part, "podPath" => pod_path,
      "controlledDigest" => controlled_digest, "requestId" => request_id
    }.merge(details || {}).compact
  end
end
