# frozen_string_literal: true

require "json"

# The signature of the economic operator over a passport (docs/Integrity.md
# section 10).
#
# The commitment of PayloadCommitment is written with the key of the passport
# identifier, so it says that the content is the one attested, not who attested
# it. This is the other half: a compact JWS, signed with the document key of the
# economic operator's own DID, whose payload is the public part of the passport
# in the full representation -- exactly what a reader without access rights
# receives, and exactly what the commitment covers.
#
# Three properties decide the shape of this class:
#
#   * the service never signs. It holds no key of the economic operator and
#     must not: a signature it could produce would prove nothing about who
#     stands behind the passport. It checks, keeps, and hands out.
#   * a signature that does not match is worse than none. A verifier that finds
#     a JWS whose payload differs from the passport, or whose key no longer
#     verifies it, reports the passport as broken; one that finds no JWS reports
#     it as unsigned. So every write discards the signature (Dpp), every
#     delivery compares the payload with what would be delivered as JSON, and
#     the key is checked again on reads (refresh).
#   * content, not bytes. The commitment hashes the bytes a custodian delivers;
#     the signature is compared as JSON, so the order of keys and whitespace
#     do not matter (RFC 8785 gives the same canonical form for equal values).
class OperatorSignature
  NONE    = "none"
  PENDING = "pending"
  SIGNED  = "signed"
  STALE   = "stale"

  MEDIA_TYPE = "application/jose"
  ALGORITHM  = "EdDSA"

  # The verification method a signature has to name: the document key of the
  # DID, the one that also signs its bearer tokens.
  KEY_FRAGMENT = "#key-doc"

  # How long a checked key is trusted before it is checked again on a read.
  # Set to how long DidTokenVerifier keeps a resolved key, so a re-check
  # rarely needs the network.
  RECHECK_INTERVAL = ENV.fetch("DPP_SIGNATURE_RECHECK_INTERVAL", 300).to_i

  # A passport is not large; a body many times its size is not a signature.
  MAX_BYTES = ENV.fetch("DPP_SIGNATURE_MAX_BYTES", 5 * 1024 * 1024).to_i

  # A refused signature. +status+ is the generic status code of
  # EN 18222:2026 Table 15 the refusal is answered with.
  class Refused < StandardError
    attr_reader :status

    def initialize(message, status: "ClientErrorBadRequest")
      @status = status
      super(message)
    end
  end

  class << self
    # The state as it is reported: NONE for a passport never signed.
    def state(dpp) = dpp.signature_state.presence || NONE

    # Takes a compact JWS apart (CompactJws). Raises Refused when it is not one
    # with the header and payload of docs/Integrity.md section 10.
    def parse(text)
      compact = text.to_s.strip
      raise Refused, "the request body has to be a JWS in the compact serialization" if compact.empty?
      raise Refused, "the JWS is larger than #{MAX_BYTES} bytes" if compact.bytesize > MAX_BYTES

      jws = begin
        CompactJws.parse(compact)
      rescue CompactJws::Malformed => e
        raise Refused, "the request body is not a valid JWS: #{e.message}"
      end

      header = jws.header
      raise Refused, "alg is #{header['alg'].inspect}, expected #{ALGORITHM}" unless header["alg"] == ALGORITHM
      raise Refused, "crit is not supported" if header.key?("crit")
      raise Refused, "b64 is not supported: the payload is the passport, base64url-encoded" if header.key?("b64")
      raise Refused, "the JWS payload is not a passport (a JSON object)" unless jws.payload.is_a?(Hash)

      jws
    end

    # Checks a submitted signature and keeps it. +actor+ is the verified DID of
    # the bearer token. Returns the warnings to report (an empty list when the
    # signer is the economic operator). Raises Refused; a refused signature
    # leaves the passport as it was.
    def accept!(dpp, compact, actor:)
      if dpp.pod?
        raise Refused, "a signature is accepted for passports this service holds itself; " \
                       "this one is held by a custodian"
      end

      owner = dpp.owner_did.to_s
      if owner.empty? || actor.to_s != owner
        raise Refused.new("only the economic operator that created this passport may sign it",
                          status: "ClientForbidden")
      end

      jws = parse(compact)
      if jws.signer != owner
        raise Refused.new("kid names #{jws.signer.inspect}, not the owner of this passport, #{owner}",
                          status: "ClientForbidden")
      end
      unless jws.kid == "#{owner}#{KEY_FRAGMENT}"
        raise Refused, "kid has to name the document key, #{owner}#{KEY_FRAGMENT}"
      end

      key = DidTokenVerifier.public_key_for(owner)
      raise Refused, "#{owner} cannot be resolved, so the signature cannot be checked" if key.nil?
      raise Refused, "the signature does not verify with the document key of #{owner}" unless valid?(jws, key)

      unless same_content?(jws.payload, public_full(dpp))
        raise Refused, "the payload is not the passport as it is delivered now (its public part in the full " \
                       "representation); a write may have come in between: fetch it again and sign that"
      end

      dpp.update_columns(signature_jws: jws.compact, signature_state: SIGNED,
                         signature_checked_at: Time.now.utc)
      warnings_for(dpp, jws)
    end

    # Whether +jws+ verifies with the Ed25519 verify key +key+.
    def valid?(jws, key) = CompactJws.valid?(jws, key)

    # The JWS to hand out together with +document+, the JSON a reader would
    # get for the same request, or nil. Only a signature that is signed and
    # whose payload is exactly that document: a verifier comparing the two must
    # never find a mismatch.
    def deliverable(dpp, document)
      return nil unless dpp.signature_state == SIGNED && dpp.signature_jws.present?

      deliverable_compact(dpp.signature_jws, document)
    end

    # The same for a signature kept apart from the passport, such as that of
    # an archived version: +compact+ if its payload is exactly +document+.
    def deliverable_compact(compact, document)
      return nil if compact.blank?

      jws = parse(compact)
      same_content?(jws.payload, document) ? jws.compact : nil
    rescue Refused
      nil
    end

    # On a read. A signature whose payload no longer is the public part -- the
    # passport was changed on a path that did not discard it -- is discarded
    # now; a signed or stale one whose key was last checked longer than
    # RECHECK_INTERVAL ago is checked again. Nothing raises: a check that
    # cannot be made leaves the signature undelivered, never delivered on
    # trust.
    def refresh(dpp)
      return unless [SIGNED, STALE].include?(dpp.signature_state)

      jws = stored(dpp)
      return discard!(dpp) if jws.nil? || !same_content?(jws.payload, public_full(dpp))
      return if dpp.signature_checked_at.present? && dpp.signature_checked_at > RECHECK_INTERVAL.seconds.ago

      key = DidTokenVerifier.public_key_for(jws.signer)
      state = key && valid?(jws, key) ? SIGNED : STALE
      Rails.logger.warn("[operator-signature] #{dpp.dpp_id}: signature of #{jws.signer} no longer verifies") if state == STALE
      dpp.update_columns(signature_state: state, signature_checked_at: Time.now.utc)
    rescue StandardError => e
      Rails.logger.warn("[operator-signature] #{dpp.dpp_id}: cannot re-check the signature: #{e.class}: #{e.message}")
      dpp.update_columns(signature_state: STALE, signature_checked_at: Time.now.utc) if dpp.persisted?
    end

    # The public part in the full representation, as JSON values: what a reader
    # without access rights receives (PassportAccess), and what a signature has
    # to cover.
    def public_full(dpp)
      JSON.parse(JSON.generate(DppRepresentation.passport(dpp.published_document, DppRepresentation::FULL)))
    end

    # Equal as JSON. Hash equality ignores the order of keys and compares
    # numbers by value, which is what RFC 8785 makes of them as well.
    def same_content?(payload, document)
      payload == JSON.parse(JSON.generate(document))
    end

    private

    def stored(dpp)
      parse(dpp.signature_jws)
    rescue Refused
      nil
    end

    def discard!(dpp)
      dpp.update_columns(signature_jws: nil, signature_state: PENDING, signature_checked_at: nil)
    end

    def warnings_for(dpp, jws)
      return [] if jws.signer == dpp.economic_operator_id.to_s

      ["signed by #{jws.signer}, which is not the economicOperatorId #{dpp.economic_operator_id}: accepted " \
       "as the signature of an authorised representative, which a verifier cannot recognise as such and " \
       "reports as not issued by the economic operator"]
    end

  end
end
