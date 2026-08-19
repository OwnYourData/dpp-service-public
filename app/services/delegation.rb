# frozen_string_literal: true

require "ed25519"
require "json"
require "base64"
require "digest"

# The three signed statements of docs/Delegation.md: the delegation assertion
# (§5) that the economic operator signs, and the client assertion plus DPoP
# proof (§6) that this service signs for itself.
#
# Two properties matter and are the reason this is hand-rolled instead of
# delegated to the jwt gem:
#
#   1. Byte-exact serialisation. Both sides of this protocol — the pod and this
#      service — have to produce the same signing input from the same claims,
#      otherwise signatures verify on one side and not on the other. Every JSON
#      object that goes into a signature is written with sorted keys and no
#      insignificant whitespace, which is what spec/fixtures/delegation-vectors
#      pins down. The jwt gem inserts its own header members ("typ": "JWT") and
#      does not promise a key order.
#   2. No private key of the customer, ever. This class can *verify* a
#      delegation and it can *sign* the service's own statements. It has no path
#      that signs a delegation, because the service does not hold the key that
#      would be needed — see verify! and ServiceDid.
class Delegation
  ALGORITHM      = "EdDSA"
  TYP_DELEGATION = "dpp-delegation+jwt"
  TYP_CLIENT     = "client-assertion+jwt"
  TYP_DPOP       = "dpop+jwt"

  # §10. The client assertion and the DPoP proof are minted per request, so
  # their lifetimes are the replay window; rules 7 and 9 in §8 check them.
  CLIENT_ASSERTION_LIFETIME = 60
  DPOP_LIFETIME             = 30

  # §8 rule 4. A delegation that outlives this is refused on the way in, so a
  # mis-signed 10-year mandate is caught here rather than at the pod.
  MAX_LIFETIME = ENV.fetch("DPP_DELEGATION_MAX_LIFETIME", 90 * 86_400).to_i

  # §8 rule 4, tolerance for clock skew between customer, service and pod.
  CLOCK_SKEW = 60

  # D3: extensible on purpose. Adding a value is a change here, not a migration.
  KNOWN_ACT = %w[create update delete].freeze

  class Error < StandardError; end

  # Refused delegation. +code+ is the OAuth error of §14, so the caller can map
  # it without re-deciding: invalid_grant, insufficient_scope, invalid_dpop_proof.
  class Invalid < Error
    attr_reader :code

    def initialize(message, code: "invalid_grant")
      @code = code
      super(message)
    end
  end

  class << self
    # ---------------------------------------------------------------- signing

    # Client assertion (§6, RFC 7523 §3): "I am the service the delegation names".
    def client_assertion(token_endpoint, now: Time.now.to_i, jti: random_jti,
                         did: ServiceDid.did, key: ServiceDid.signing_key)
      sign(key, typ: TYP_CLIENT, kid: "#{did}#key-doc", payload: {
             "iss" => did,
             "sub" => did,
             "aud" => token_endpoint,
             "iat" => now,
             "exp" => now + CLIENT_ASSERTION_LIFETIME,
             "jti" => jti
           })
    end

    # DPoP proof (§6, RFC 9449): "I hold the key this token is bound to".
    # The public key travels in the header as a JWK; the pod binds the access
    # token to its thumbprint and later accepts it only with a matching proof.
    #
    # +ath+ is the access token the proof accompanies. RFC 9449 §7.1 requires
    # its hash in every proof sent to a protected resource, so a proof captured
    # from one request cannot be replayed with a different token. Token requests
    # have no access token yet and therefore no ath — which is why the vectors,
    # which all target the token endpoint, do not carry one. §6 of
    # docs/Delegation.md does not mention ath; sending it is harmless for a pod
    # that ignores it and correct for one that follows the RFC.
    def dpop_proof(htm:, htu:, now: Time.now.to_i, jti: random_jti, ath: nil,
                   key: ServiceDid.signing_key)
      payload = { "htm" => htm, "htu" => htu, "iat" => now, "jti" => jti }
      payload["ath"] = b64u(Digest::SHA256.digest(ath)) if ath.present?

      sign(key, typ: TYP_DPOP, jwk: jwk_for(key.verify_key), payload: payload)
    end

    # RFC 7638 thumbprint of a JWK. For OKP the required members are crv, kty, x.
    def jkt(jwk)
      b64u(Digest::SHA256.digest(canonical(jwk)))
    end

    def jwk_for(verify_key)
      { "crv" => "Ed25519", "kty" => "OKP", "x" => b64u(verify_key.to_bytes) }
    end

    # ------------------------------------------------------------ verifying

    # Checks a delegation the customer signed and handed us, before we store it.
    #
    # This is deliberately stricter than "does the signature check out": a
    # delegation naming a different service, a different pod or a different
    # collection is not ours to keep, and storing it would only move the failure
    # to the first token request, where the pod's log would carry the blame.
    #
    # Returns the claims. Raises Invalid, carrying the §14 error code.
    def verify!(token, audience:, collection_id: nil, service_did: ServiceDid.did,
                now: Time.now.to_i)
      header, claims = decode(token)

      raise Invalid, "typ is #{header['typ'].inspect}, expected #{TYP_DELEGATION}" \
        unless header["typ"] == TYP_DELEGATION
      raise Invalid, "alg is #{header['alg'].inspect}, expected #{ALGORITHM}" \
        unless header["alg"] == ALGORITHM

      %w[iss sub aud collection product_id act purpose iat nbf exp jti].each do |claim|
        raise Invalid, "claim #{claim} is missing" if claims[claim].nil?
      end

      issuer = claims["iss"].to_s
      raise Invalid, "iss is not a DID" unless issuer.start_with?("did:")

      # Rule 2. Same resolution and the same cache as the bearer tokens of
      # prEN 18239 — a DID revoked by its holder stops working here too.
      key = DidTokenVerifier.public_key_for(issuer)
      raise Invalid, "cannot resolve #{issuer}" if key.nil?
      verify_signature!(token, key)

      # Rule 8, seen from this side: a delegation for another service is not a
      # delegation for us. Checking it here is what stops us from storing an
      # artefact we can never redeem.
      raise Invalid, "sub #{claims['sub'].inspect} is not this service" \
        unless claims["sub"] == service_did

      raise Invalid, "aud #{claims['aud'].inspect} is not #{audience}" \
        unless claims["aud"] == audience

      if collection_id && claims["collection"].to_s != collection_id.to_s
        raise Invalid, "collection #{claims['collection'].inspect} is not #{collection_id}"
      end

      # Rule 4.
      raise Invalid, "not valid yet (nbf #{claims['nbf']})" if now + CLOCK_SKEW < claims["nbf"].to_i
      raise Invalid, "expired (exp #{claims['exp']})"       if now - CLOCK_SKEW > claims["exp"].to_i

      lifetime = claims["exp"].to_i - claims["iat"].to_i
      raise Invalid, "lifetime #{lifetime}s exceeds #{MAX_LIFETIME}s" if lifetime > MAX_LIFETIME

      # Rule 11 / D2. One passport per delegation; a wildcard would turn the
      # object binding the model rests on back into an account binding.
      product_id = claims["product_id"].to_s
      raise Invalid, "product_id must be one concrete identifier" \
        if product_id.empty? || product_id.include?("*")

      # Rule 10 / D3. Unknown values fail closed rather than being ignored,
      # and both cases answer insufficient_scope per §14.
      act = claims["act"]
      raise Invalid.new("act must be a non-empty array", code: "insufficient_scope") \
        unless act.is_a?(Array) && act.any?

      unknown = act.map(&:to_s) - KNOWN_ACT
      raise Invalid.new("act contains #{unknown.inspect}", code: "insufficient_scope") \
        if unknown.any?

      claims
    end

    # True when this delegation still covers +operation+ (create/update/delete)
    # and has not expired. Used before a write, so the service fails on its own
    # terms instead of discovering it at the pod.
    def covers?(claims, operation, now: Time.now.to_i)
      return false if claims.nil?
      return false unless Array(claims["act"]).map(&:to_s).include?(operation.to_s)

      now - CLOCK_SKEW <= claims["exp"].to_i
    end

    # Claims without verifying anything. For logging and for reading back what
    # we stored; never for a decision.
    def peek(token)
      _header, claims = decode(token)
      claims
    rescue StandardError
      nil
    end

    # ------------------------------------------------------------ primitives

    # JSON with sorted keys and no insignificant whitespace — the serialisation
    # both implementations have to agree on, byte for byte.
    #
    # Non-ASCII is refused rather than escaped: Ruby emits it raw, Python's
    # json.dumps escapes it by default, and the two signing inputs would differ
    # in a way that is invisible in a diff of the claims. Every claim in §5 is
    # an identifier, a URL or a number, so this costs nothing today and turns a
    # silent signature mismatch into an exception if that ever changes.
    def canonical(obj)
      json = JSON.generate(deep_sort(obj))
      raise Error, "non-ASCII in a signed claim set" unless json.ascii_only?

      json
    end

    def b64u(raw)
      Base64.urlsafe_encode64(raw, padding: false)
    end

    def b64u_decode(str)
      Base64.urlsafe_decode64(str + "=" * ((4 - str.length % 4) % 4))
    end

    def sign(key, typ:, payload:, kid: nil, jwk: nil)
      header = { "alg" => ALGORITHM, "typ" => typ }
      header["kid"] = kid if kid
      header["jwk"] = jwk if jwk

      signing_input = "#{b64u(canonical(header))}.#{b64u(canonical(payload))}"
      "#{signing_input}.#{b64u(key.sign(signing_input))}"
    end

    def random_jti
      SecureRandom.hex(8)
    end

    private

    def decode(token)
      parts = token.to_s.split(".")
      raise Invalid, "not a three-part JWS" unless parts.length == 3

      [JSON.parse(b64u_decode(parts[0])), JSON.parse(b64u_decode(parts[1]))]
    rescue JSON::ParserError, ArgumentError => e
      raise Invalid, "malformed token: #{e.class}"
    end

    def verify_signature!(token, verify_key)
      parts = token.to_s.split(".")
      verify_key.verify(b64u_decode(parts[2]), "#{parts[0]}.#{parts[1]}")
    rescue StandardError => e
      # The ed25519 library raises ArgumentError on a malformed signature and
      # Ed25519::VerifyError on a wrong one. Both mean the same thing here.
      raise Invalid, "signature does not verify (#{e.class})"
    end

    def deep_sort(obj)
      case obj
      when Hash  then obj.keys.map(&:to_s).sort.to_h { |k| [k, deep_sort(obj[k] || obj[k.to_sym])] }
      when Array then obj.map { |v| deep_sort(v) }
      else obj
      end
    end
  end
end
