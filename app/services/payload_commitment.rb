# frozen_string_literal: true

require "net/http"
require "uri"

# Binds the content of a passport to its identifier (prEN 18246; the procedure is
# docs/Integrity.md section 4).
#
# What is hashed is not what this service holds but **what the custodian
# actually delivers**: the bytes returned by the serviceEndpoint of the DID
# document, with no canonicalisation. A reader recomputes exactly that, so the
# subject of the hash has to be exactly that -- fetching the payload back is
# therefore not a detour, it is the only way the value cannot drift from what a
# reader sees. It also means the custodian's byte-identical delivery is
# re-verified on every write.
#
# Variante A (this service holds the document key) ends in "committed": the hash
# is written into the DID document as a signed log entry. Variante B ends in
# "pending" with the hash recorded -- the holder has to sign that entry, and
# section 6 asks the service to report the expected hash rather than to refuse
# the write.
#
# Nothing here raises. A commitment that cannot be written must not fail the
# write that was already accepted by the custodian (availability argument in
# section 6); it leaves the passport "pending", which the read paths report.
class PayloadCommitment
  class Error < StandardError; end

  COMMITTED = "committed"
  PENDING   = "pending"
  STALE     = "stale"

  # Same digest and encoding the pod forms its DRI with, so pod and DID document
  # carry the same value (section 4). These are oydid's own defaults; they are
  # named here because the agreement is what matters, not the default.
  DIGEST_OPTIONS = { digest: "sha2-256", encode: "base58btc" }.freeze

  OPEN_TIMEOUT = ENV.fetch("DPP_DELIVERY_OPEN_TIMEOUT", 5).to_i
  READ_TIMEOUT = ENV.fetch("DPP_DELIVERY_READ_TIMEOUT", 10).to_i

  # How long a checked state is trusted before the DID is resolved again. The
  # read paths call +refresh+, so without this a crawler on a pending passport
  # would decide how much work the service does.
  RECHECK_INTERVAL = ENV.fetch("DPP_COMMIT_RECHECK_INTERVAL", 60).to_i

  def self.call(dpp) = new(dpp).call

  # Read side: has the holder published the entry in the meantime?
  #
  # Variante B only ever reaches "pending" through a write — the service holds no
  # document key and cannot sign. What it can do is look: resolve the DID and see
  # whether the document now commits to the payload the service last delivered.
  # Nothing is written to the VDR here, and nothing raises; a passport whose state
  # cannot be determined keeps the one it has.
  def self.refresh(dpp)
    return dpp&.did_commit_state unless dpp&.did_commit_state == PENDING
    return PENDING unless dpp.dpp_id.to_s.start_with?("did:oyd:")
    return PENDING if dpp.payload_hash.blank?
    if dpp.payload_checked_at.present? && dpp.payload_checked_at > RECHECK_INTERVAL.seconds.ago
      return PENDING
    end

    new(dpp).refresh
  end

  # The hash of a payload, as a reader would compute it. Binary encoding on
  # purpose: this hashes bytes, and a body that arrives as UTF-8 and one that
  # arrives as ASCII-8BIT have to give the same value.
  def self.digest(bytes)
    require "oydid"

    hash, msg = Oydid.multi_hash(bytes.to_s.dup.force_encoding(Encoding::BINARY), DIGEST_OPTIONS)
    raise Error, (msg.presence || "could not hash the delivered payload") if hash.blank?

    hash
  end

  def initialize(dpp)
    @dpp = dpp
  end

  # Returns the state the passport was left in, or nil when there is nothing to
  # commit to.
  def call
    # Only a did:oyd carries a log an entry can be appended to. A passport
    # identified by an https URL has nowhere to put a commitment, and calling it
    # "pending" would promise something that is never going to arrive.
    return nil unless dpp.dpp_id.to_s.start_with?("did:oyd:")

    hash = delivered_digest
    return record(nil, PENDING) if hash.nil?
    return record(hash, PENDING) unless dpp.did_managed?

    commit(hash) ? record(hash, COMMITTED) : record(hash, PENDING)
  end

  # Compare the commitment in the DID document with the payload this service
  # delivered. Committed when they agree; stale when the document attests some
  # other payload, which is what a reader has to be told rather than left to
  # discover.
  def refresh
    committed = commitment_in_document
    state = if committed.blank?
              PENDING
            elsif committed == dpp.payload_hash
              COMMITTED
            else
              STALE
            end
    record(dpp.payload_hash, state, checked: true)
  rescue DidOyd::DidError, Error => e
    log("cannot re-check the commitment: #{e.message}")
    record(dpp.payload_hash, PENDING, checked: true)
  end

  private

  attr_reader :dpp

  def commitment_in_document
    content = DidOyd.document_content(dpp.dpp_id)
    entry = Array(content["service"])
            .find { |e| e.is_a?(Hash) && e["type"].to_s == DidOyd::SERVICE_TYPE }
    entry && entry[DidOyd::PAYLOAD_HASH].to_s.presence
  end

  # The bytes a reader gets, hashed. For a pod-backed passport that is a public
  # GET against the serviceEndpoint -- no token, exactly the request a consumer
  # makes.
  #
  # For a passport kept in this database there is no second party: this service
  # is the custodian, so its own rendering of the document is what it delivers.
  # That is a weaker statement than the pod case, because it hashes the document
  # rather than a response, and it is the only case in which the two could drift.
  def delivered_digest
    bytes = dpp.pod? ? fetch(delivery_endpoint) : JSON.generate(dpp.to_document)
    self.class.digest(bytes)
  rescue DidOyd::DidError, Error, PodStorage::Error => e
    log("cannot determine the delivered payload: #{e.message}")
    nil
  end

  # Where a reader is sent: the endpoint in the DID document itself, not a URL
  # rebuilt from configuration. If the two ever disagree, the document is what
  # counts.
  def delivery_endpoint
    endpoint = DidOyd.service_endpoint(dpp.dpp_id)
    raise Error, "#{dpp.dpp_id} carries no service endpoint to read from" if endpoint.blank?

    endpoint
  end

  def fetch(url)
    uri = URI.parse(url.to_s)
    request = Net::HTTP::Get.new(uri, "Accept" => "application/json")
    response = Net::HTTP.start(uri.hostname, uri.port,
                               use_ssl: uri.scheme == "https",
                               open_timeout: OPEN_TIMEOUT,
                               read_timeout: READ_TIMEOUT) { |http| http.request(request) }

    raise Error, "#{url} answered #{response.code}" if response.code.to_i != 200

    response.body.to_s
  rescue Net::OpenTimeout, Net::ReadTimeout
    raise Error, "#{url} timed out"
  rescue SystemCallError, SocketError, OpenSSL::SSL::SSLError => e
    raise Error, "#{url} unreachable (#{e.class}: #{e.message})"
  end

  # Appends the signed log entry. True when the DID document commits to this
  # hash afterwards -- including the case where it already did, which oydid
  # answers with nil rather than writing an entry that changes nothing.
  def commit(hash)
    result = DidOyd.update(dpp.dpp_id, payload_hash: hash,
                                       doc_key: dpp.did_doc_key,
                                       rev_key: dpp.did_rev_key)
    return true if result.nil?

    # Always store what came back. A non-rotating update hands the same pair
    # back, but oydid generates a fresh one whenever the options do not pin it,
    # and a passport whose stored keys no longer match its document can never be
    # updated or revoked again.
    dpp.did_doc_key = result[:doc_key]
    dpp.did_rev_key = result[:rev_key]
    dpp.did_rev_log = serialize(result[:rev_log])
    @head = result[:head]
    true
  rescue DidOyd::DidError => e
    log("commitment left pending: #{e.message}")
    false
  end

  # KeyVault stores strings, and Hash#to_s would leave Ruby inspect syntax
  # behind. The revocation record belongs to the new document and is only of use
  # if it can be read back.
  def serialize(value)
    value.is_a?(String) || value.nil? ? value : JSON.generate(value)
  end

  # +checked+ marks a state that came from looking at the VDR rather than from
  # writing to it — that is what the throttle counts.
  def record(hash, state, checked: false)
    dpp.payload_hash       = hash
    dpp.did_commit_state   = state
    dpp.did_head           = @head if @head.present?
    dpp.payload_checked_at = Time.now.utc if checked
    dpp.save!
    state
  end

  def log(message)
    Rails.logger.warn("[payload-commitment] #{dpp.dpp_id}: #{message}")
  end
end
