# frozen_string_literal: true

require "cgi"

# Thin wrapper around the oydid gem for the did:oyd operations the DPP Service
# needs in Variante A. Keeping oydid behind this seam lets specs stub it, so the
# test/dev environment needs neither libsodium nor network access.
#
# prEN 18219 (§5.3, W3C DID) is the normative basis; the DID document carries a
# service endpoint (prEN 18220 discovery) pointing back to the public read URL.
class DidOyd
  class DidError < StandardError; end

  DEFAULT_LOCATION = "https://oydid.ownyourdata.eu"

  # oydid >= 0.5 supports several key types and no longer defaults to ed25519;
  # without this Oydid.create raises NoMethodError (nil + "-priv") inside
  # generate_base.
  KEY_TYPE = "ed25519"

  # OYDID repository / VDR that the DID document is published to and resolved
  # from (prEN 18246 anchor). Default is the public OwnYourData instance.
  def self.location
    ENV.fetch("OYDID_LOCATION", DEFAULT_LOCATION)
  end

  # For the default repository oydid appends "@https://oydid.ownyourdata.eu" to
  # the identifier. That suffix is redundant (resolution falls back to the
  # default location), so strip it for the default repo — both in storage and
  # in output. For a non-default repo the location is required for resolution
  # and is therefore kept.
  def self.normalize_did(did)
    return did.to_s unless location == DEFAULT_LOCATION

    did.to_s.sub(
      /@(#{Regexp.escape(DEFAULT_LOCATION)}|#{Regexp.escape(CGI.escape(DEFAULT_LOCATION))})\z/, ""
    )
  end

  # Public base URL of this DPP Service, used to build the DID's serviceEndpoint.
  def self.endpoint_base
    ENV.fetch("DPP_SERVICE_ENDPOINT_BASE", "https://dpp-service.ownyourdata.eu")
  end

  # Mint a new did:oyd for the given product. The serviceEndpoint resolves to
  # the (stable, already-known) public ReadDPPByProductId URL, so it does not
  # depend on the DID that is only known after minting.
  #
  # +endpoint_base+ overrides this service's own public URL. For a pod-backed
  # DPP (S2) it is the pod's base_url, so a consumer following the DID lands at
  # the pod — the same host that also serves the short-link UPI. The value is
  # frozen into the DID document at mint time; changing it later requires a DID
  # update, which is why the storage token has to be present at CreateDPP.
  #
  # Returns { did:, doc_key:, rev_key:, rev_log: } (secrets in memory).
  def self.mint(product_id, endpoint_base: nil)
    require "oydid"

    base = endpoint_base.presence || self.endpoint_base
    content = {
      "service" => [{
        "type" => "DigitalProductPassport",
        "serviceEndpoint" => "#{base}/dpp/v1/dppsByProductId/#{CGI.escape(product_id.to_s)}"
      }]
    }

    # :location goes into the identifier itself (the "@<repo>" suffix that
    # normalize_did strips again for the default repo), :doc_location is the
    # repository document and log are published to. Up to oydid 0.4 a single
    # :doc_location covered both; since 0.5 they are separate options, and
    # passing only :doc_location silently mints a DID without its location
    # suffix — resolvable only at the default repository.
    result, msg = Oydid.create(content, { return_secrets: true,
                                          key_type: KEY_TYPE,
                                          location: location,
                                          doc_location: location })
    raise DidError, (msg.presence || "Oydid.create returned no result") if result.nil?

    {
      did:     normalize_did(result["did"]),
      doc_key: result["private_key"],
      rev_key: result["revocation_key"],
      rev_log: result["revocation_log"]
    }
  end

  # Revoke a service-managed did:oyd using the stored keys (Variante A only).
  #
  # The option names are deliberate and easy to get wrong: oydid decides which
  # branch to take by :doc_enc / :rev_enc but reads the key material from
  # :old_doc_enc / :old_rev_enc, so both have to be set to the same value.
  # Passing only :doc_key / :rev_key (as this wrapper did before) makes oydid
  # look for key *files* on disk and fail with "invalid or missing old private
  # document key" — a message that points at the keys rather than at the caller.
  def self.revoke(did, doc_key:, rev_key:)
    require "oydid"

    _log, msg = Oydid.revoke(did, { doc_enc:     doc_key, old_doc_enc: doc_key,
                                    rev_enc:     rev_key, old_rev_enc: rev_key,
                                    key_type:    KEY_TYPE,
                                    doc_location: location })
    raise DidError, msg if msg.to_s != ""
    true
  end
end
