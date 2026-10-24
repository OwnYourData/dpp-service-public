# frozen_string_literal: true

# One entry of the write log (WriteLog, docs/Integrity.md section 11). Entries
# are only ever added: a saved entry is read-only, and destroying one is
# refused. Pruning after the retention period (WriteLog.prune!) is the one way
# entries leave, and it is not reachable over the API.
class WriteEvent < ApplicationRecord
  PHASES = %w[request outcome].freeze

  class AppendOnly < StandardError; end

  validates :phase, inclusion: { in: PHASES }
  validates :request_id, :occurred_at, presence: true

  before_destroy { raise AppendOnly, "the write log is append-only" }

  def readonly? = persisted? || super

  # The entry as the export hands it to the owner: everything, the token
  # included, since a spent token is the evidence.
  def export
    { "at" => occurred_at.utc.iso8601(6), "phase" => phase, "requestId" => request_id,
      "operation" => operation, "dppId" => dpp_id, "issuer" => issuer, "jti" => jti,
      "token" => token, "rqh" => request_hash, "bound" => bound, "method" => http_method,
      "target" => target, "bodyDigest" => body_digest, "status" => status,
      "version" => version_number }.compact
  end
end
