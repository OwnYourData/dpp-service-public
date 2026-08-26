# frozen_string_literal: true

require "jwt"
require "ed25519"
# Registers the EdDSA algorithm with the jwt gem. Without it every EdDSA token
# is refused with "Unsupported signing method" — the gem ships algorithms
# separately and oydid, which pulls jwt-eddsa in, is loaded lazily.
require "jwt/eddsa"
require "timeout"

# Verifies self-issued bearer tokens against the DID of their issuer
# (prEN 18239 §6.2, on the identifier basis of EN 18219:2026).
#
# The economic operator signs a short-lived JWT with the document key of its own
# did:oyd. This service resolves the DID, takes the public key out of the DID
# document and verifies the signature — no central identity provider, and a
# revoked DID stops working on its own.
#
# Expected token:
#
#   Header   { "alg": "EdDSA", "kid": "<did>#key-doc", "typ": "JWT" }
#   Payload  { "iss": "<did>", "sub": "<did>",
#              "aud": "<public base URL of this service>",
#              "iat": …, "exp": … , "jti": … }
#
# +aud+ is what keeps a token issued for a different service from being replayed
# here; together with a short lifetime that is the replay defence. A +jti+ store
# would close the remaining window and can be added later.
class DidTokenVerifier
  ALGORITHM = "EdDSA"

  # Resolving a did:oyd goes over the network and takes ~1–2 s. Verifying every
  # request that way is not viable, and an attacker could force unbounded
  # outbound lookups with invented DIDs. Both are handled by caching the public
  # key — and by caching failures too, which is what bounds the abuse.
  #
  # The positive TTL is also the window in which a revoked DID is still
  # accepted. Shorten it if that matters more than latency.
  CACHE_TTL          = ENV.fetch("DID_AUTH_CACHE_TTL", 300).to_i
  NEGATIVE_CACHE_TTL = ENV.fetch("DID_AUTH_NEGATIVE_CACHE_TTL", 60).to_i
  RESOLVE_TIMEOUT    = ENV.fetch("DID_AUTH_RESOLVE_TIMEOUT", 10).to_i

  # Tokens are meant to be short-lived. A long-lived one is not necessarily
  # forged, but it defeats the point of not having revocation, so it is refused.
  MAX_LIFETIME = ENV.fetch("DID_AUTH_MAX_LIFETIME", 900).to_i

  UNRESOLVABLE = "unresolvable"

  class << self
    # "did" turns verification and owner binding on. Anything else keeps the
    # previous behaviour, where the token is decoded but not verified.
    def mode
      ENV.fetch("DPP_AUTH_MODE", "permissive")
    end

    def enabled?
      mode == "did"
    end

    # The value a token's +aud+ has to carry. Defaults to this service's public
    # base URL, which is what a client can discover.
    def audience
      ENV.fetch("DPP_AUTH_AUDIENCE", DidOyd.endpoint_base)
    end

    # Returns the verified claims, or nil if the token is not acceptable.
    # Never raises: every failure is an authentication failure.
    def call(token)
      claims = verify!(token)
      claims
    rescue StandardError => e
      # Deliberately StandardError, not JWT::DecodeError: a tampered signature
      # surfaces as ArgumentError from the ed25519 library, and that would
      # otherwise become a 500 instead of a 401.
      Rails.logger.info("[did-auth] rejected: #{e.class}: #{e.message}")
      nil
    end

    # Ed25519 public key of the DID's document key, from cache or the VDR.
    #
    # Public because the delegation model (docs/Delegation.md §8 rule 2) needs
    # exactly this and nothing else from here: resolve a DID, cache the answer,
    # hand back a key. Sharing it keeps one resolution cache and one revocation
    # window in the service instead of two that drift apart.
    #
    # Written explicitly rather than through Rails.cache.fetch, because hits and
    # misses need different lifetimes: a failure is cached only briefly (that is
    # what bounds abuse without pinning a temporary outage for minutes), a key
    # for as long as we are willing to miss a revocation.
    def public_key_for(did)
      cache_key = "did-auth/key/#{did}"
      cached = Rails.cache.read(cache_key)

      if cached.nil?
        raw = resolve_public_key(did)
        if raw
          Rails.cache.write(cache_key, raw, expires_in: CACHE_TTL)
          cached = raw
        else
          Rails.cache.write(cache_key, UNRESOLVABLE, expires_in: NEGATIVE_CACHE_TTL)
          cached = UNRESOLVABLE
        end
      end
      return nil if cached == UNRESOLVABLE

      Ed25519::VerifyKey.new(cached)
    end

    private

    def verify!(token)
      unverified_payload, header = JWT.decode(token.to_s, nil, false)

      raise JWT::IncorrectAlgorithm, "expected #{ALGORITHM}" if header["alg"] != ALGORITHM

      issuer = unverified_payload["iss"].to_s
      raise JWT::InvalidIssuerError, "iss is not a DID" unless issuer.start_with?("did:")

      key = public_key_for(issuer)
      raise JWT::VerificationError, "cannot resolve #{issuer}" if key.nil?

      claims, = JWT.decode(token.to_s, key, true,
                           algorithm:          ALGORITHM,
                           aud:                audience,
                           verify_aud:         true,
                           verify_expiration:  true,
                           verify_iat:         true,
                           required_claims:    %w[iss aud exp])

      lifetime = claims["exp"].to_i - claims["iat"].to_i
      if claims["iat"] && lifetime > MAX_LIFETIME
        raise JWT::InvalidPayload, "token lifetime #{lifetime}s exceeds #{MAX_LIFETIME}s"
      end
      if claims["sub"].present? && claims["sub"] != issuer
        raise JWT::InvalidSubError, "sub does not match iss (token is not self-issued)"
      end

      claims
    end

    # Returns the raw 32 key bytes, or nil. The DID document holds
    # "<document key>:<revocation key>"; only the document key signs.
    def resolve_public_key(did)
      require "oydid"

      info = Timeout.timeout(RESOLVE_TIMEOUT) { Oydid.read(did, {}).first }
      return nil if info.nil? || info["error"].to_i != 0

      multibase = info.dig("doc", "key").to_s.split(":").first
      return nil if multibase.blank?

      # multi_decode yields the multicodec prefix followed by the key; for
      # ed25519-pub that is two bytes of varint plus 32 bytes.
      raw = Oydid.multi_decode(multibase).first
      return nil if raw.nil? || raw.bytesize < 32

      raw[-32..]
    rescue StandardError => e
      Rails.logger.info("[did-auth] cannot resolve #{did}: #{e.class}: #{e.message}")
      nil
    end
  end
end
