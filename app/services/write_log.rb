# frozen_string_literal: true

# The write log (docs/Integrity.md section 11): evidence that the economic
# operator asked for each change, kept by the service and not handed out over
# the API.
#
# Every request that changes something has two entries:
#
#   request  written once the bearer token is verified and bound
#            (RequestBinding), before anything is changed: the issuer, the
#            token, which is spent with its first use (TokenUse), what it binds
#            -- method, request-target, the digest of the body -- the
#            operation and the passport named in the path. If it cannot be
#            written, the request is refused and nothing changes.
#   outcome  written when the request ends: its HTTP status, the passport
#            (known only now for CreateDPP) and the version the write produced,
#            or for DeleteDPPById the archived final version.
#
# No body and no passport content: the body is bound only by its digest, the
# content is in the archived versions. The operator exports the entries of a
# passport for its owner (export), who checks them with bin/verify_writes.
#
# Entries are kept for RETENTION_DAYS (ten years by default), and those of a
# passport for as long as the passport or one of its archived versions exists
# -- which, as versions are not removed (EN 18221:2026), is for good. prune!
# removes only older entries that name no passport, or a passport of which
# nothing is left.
module WriteLog
  RETENTION_DAYS = ENV.fetch("DPP_WRITE_LOG_RETENTION_DAYS", 3653).to_i

  module_function

  def request!(request_id:, operation:, dpp_id:, issuer:, jti:, token:, request_hash:, bound:,
               http_method:, target:, body_digest:)
    WriteEvent.create!(occurred_at: now, phase: "request", request_id: request_id, operation: operation,
                       dpp_id: dpp_id, issuer: issuer, jti: jti, token: token, request_hash: request_hash,
                       bound: bound, http_method: http_method, target: target, body_digest: body_digest)
  end

  def outcome!(request_id:, operation:, dpp: nil, dpp_id: nil, status:)
    WriteEvent.create!(occurred_at: now, phase: "outcome", request_id: request_id, operation: operation,
                       dpp_id: dpp&.dpp_id || dpp_id, status: status, version_number: version_of(dpp))
  end

  # The version the passport is at after a write: the archived versions are
  # the states before each change, so the current one comes after them. A
  # deleted passport's last version is its archived final state. nil where the
  # versions are kept by a custodian.
  def version_of(dpp)
    return nil if dpp.nil? || dpp.pod?

    archived = DppVersion.where(dpp_id: dpp.dpp_id).maximum(:version_number).to_i
    dpp.destroyed? ? archived : archived + 1
  end

  # The entries of a passport, oldest first, for its owner.
  def export(dpp_id:, since: nil)
    scope = WriteEvent.where(dpp_id: dpp_id)
    scope = scope.or(WriteEvent.where(request_id: scope.select(:request_id)))
    scope = scope.where(occurred_at: since..) if since
    scope.order(:occurred_at, :id)
  end

  def prune!(now: Time.now.utc, days: RETENTION_DAYS)
    cutoff = now - days.days
    WriteEvent.transaction do
      connection = WriteEvent.connection
      connection.execute("SET LOCAL dpp.write_log_prune = 'on'") if connection.adapter_name.downcase.include?("postg")
      # A request is kept with all its entries while either of them names a
      # passport that is still there: the request entry of CreateDPP names
      # none, its outcome does.
      kept = WriteEvent.where("dpp_id IN (SELECT dpp_id FROM dpp_versions UNION SELECT dpp_id FROM dpps)")
                       .select(:request_id)
      WriteEvent.where(occurred_at: ...cutoff).where.not(request_id: kept).delete_all
    end
  end

  def now = Time.now.utc
end
