# frozen_string_literal: true

require "ed25519"

# The identity this service signs with when it acts as a client at a hosting pod
# (docs/Delegation.md §3 and §6): the client assertion says "I am the service the
# delegation names", the DPoP proof says "I hold the key that token is bound to".
#
# Deliberately separate from the passport keys of variant A. Those are per
# passport, live in the database encrypted under KEY_VAULT_KEK, and are used
# once at DeleteDPPById to revoke a DID. This one is a single long-lived
# identity of the deployment, it is used on every write to a pod, and it never
# touches the database — it comes from the environment, so rotating it is
# replacing a secret and restarting, not a migration. §9 asks for exactly that
# separation: after the changeover KEY_VAULT_KEK protects passport keys only.
#
#   DPP_SERVICE_DID       did:oyd:… of this deployment
#   DPP_SERVICE_DOC_KEY   its document key, multibase (z1S5…), as the registrar
#                         returns it in didState.secret.documentKey
#
# The private key is only ever read into memory. Nothing in this class writes it
# anywhere, and the discovery document below deliberately exposes the DID and the
# audience and nothing else.
class ServiceDid
  class NotConfigured < StandardError; end

  class << self
    def did
      ENV["DPP_SERVICE_DID"].presence
    end

    def configured?
      did.present? && ENV["DPP_SERVICE_DOC_KEY"].present?
    end

    # Ed25519::SigningKey for the client assertion and the DPoP proof.
    # Raises rather than returning nil: a service that cannot sign cannot write
    # to a pod at all, and discovering that at the first request is better than
    # silently falling back to something weaker.
    def signing_key
      unless configured?
        raise NotConfigured,
              "DPP_SERVICE_DID and DPP_SERVICE_DOC_KEY must be set to store passports in a pod"
      end

      @signing_key ||= build_signing_key(ENV.fetch("DPP_SERVICE_DOC_KEY"))
    end

    def verify_key
      signing_key.verify_key
    end

    # What a customer needs in order to write a delegation for us: the DID goes
    # into the delegation's `sub`, the audience is where their own bearer token
    # is addressed. §6: this is discovery, not a security mechanism — the pod
    # learns our key from the DPoP proof and our identity from the resolvable
    # DID, never from this endpoint.
    def discovery_document
      { "did" => did, "audience" => DidTokenVerifier.audience }
    end

    # Does the configured private key actually belong to the configured DID?
    # Resolves the DID (through the shared cache) and compares public keys.
    #
    # Not called per request — a mismatch would only surface at the pod as a
    # signature failure, which is a confusing place to learn about a typo in a
    # secret. Meant for a deployment check and for the specs.
    def consistent?
      return false unless configured?

      resolved = DidTokenVerifier.public_key_for(did)
      return false if resolved.nil?

      resolved.to_bytes == verify_key.to_bytes
    rescue StandardError
      false
    end

    # Specs and console: forget a key read from a since-changed environment.
    def reset!
      @signing_key = nil
    end

    private

    # The registrar hands out the key multibase-encoded with a multicodec
    # prefix. Everything before the trailing 32 bytes is that prefix.
    def build_signing_key(multibase)
      require "oydid"

      raw = Oydid.multi_decode(multibase.to_s.strip).first
      if raw.nil? || raw.bytesize < 32
        raise NotConfigured, "DPP_SERVICE_DOC_KEY is not a decodable multibase key"
      end

      Ed25519::SigningKey.new(raw[-32..])
    rescue NotConfigured
      raise
    rescue StandardError => e
      raise NotConfigured, "DPP_SERVICE_DOC_KEY cannot be read (#{e.class}: #{e.message})"
    end
  end
end
