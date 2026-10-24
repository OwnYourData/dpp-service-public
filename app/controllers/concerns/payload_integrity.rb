# frozen_string_literal: true

# Reports the payload commitment (EN 18246:2026, docs/Integrity.md section 6) and
# writes it after a change.
#
# **In headers, not in the document.** A reader of the DPP document must find
# exactly the attributes of EN 18223:2026 Table 1 there; a proprietary field
# would break conformance for every reader, which is the same reason the storage
# configuration arrives in X-DPP-Storage rather than in the payload. Section 6
# asks for the state to be visible rather than silent, and a header is where a
# statement *about* the representation belongs.
#
#   X-DPP-Payload-Hash   the hash the DID document commits to, or is expected to
#   X-DPP-Commit-State   committed | pending | stale
#
# Both are omitted for a passport that has never been through a commitment, so
# nothing is asserted about the passports that predate this.
module PayloadIntegrity
  extend ActiveSupport::Concern

  HASH_HEADER  = "X-DPP-Payload-Hash"
  STATE_HEADER = "X-DPP-Commit-State"

  # After a write the custodian has already accepted. Deliberately after the
  # write and not inside it: the commitment reads the payload back from the
  # custodian, and a commitment that fails must leave the write standing.
  def commit_payload(dpp)
    PayloadCommitment.call(dpp)
    report_commitment(dpp)
  end

  # On a read: say which state the passport is in.
  #
  # A passport waiting for the holder to sign is re-checked here, because in
  # variant B nothing else would ever move it: the service holds no document key,
  # so no write of its own can turn `pending` into `committed`. The check resolves
  # the DID, which costs a second or two, and is therefore throttled per passport
  # (PayloadCommitment::RECHECK_INTERVAL) — a crawler on a pending passport must
  # not decide how much work the service does. Every other state is reported as
  # it stands, and a failed check changes nothing.
  def report_commitment(dpp)
    return if dpp.nil?

    PayloadCommitment.refresh(dpp) if dpp.did_commit_state == PayloadCommitment::PENDING

    response.set_header(HASH_HEADER, dpp.payload_hash) if dpp.payload_hash.present?
    response.set_header(STATE_HEADER, dpp.did_commit_state) if dpp.did_commit_state.present?
  end
end
