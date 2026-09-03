# frozen_string_literal: true

require "cgi"
require "timeout"
require "uri"

# Thin wrapper around the oydid gem for the did:oyd operations the DPP Service
# needs in Variante A. Keeping oydid behind this seam lets specs stub it, so the
# test/dev environment needs neither libsodium nor network access.
#
# EN 18219:2026 (§5.3, W3C DID) is the normative basis; the DID document carries a
# service endpoint (EN 18220:2026 discovery) pointing back to the public read URL.
class DidOyd
  class DidError < StandardError; end

  DEFAULT_LOCATION = "https://oydid.ownyourdata.eu"

  # The service entry a passport DID carries (EN 18220:2026 discovery).
  SERVICE_TYPE = "DigitalProductPassport"

  # Resolving goes over the network. A client-supplied identifier is checked
  # once, at CreateDPP, so this is not on a hot path -- but it must not hang.
  RESOLVE_TIMEOUT = ENV.fetch("DID_RESOLVE_TIMEOUT", 10).to_i

  # oydid supports several key types and defaults to none, so this option is
  # mandatory: without it Oydid.create raises NoMethodError (nil + "-priv")
  # inside generate_base.
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
  # the pod — the same host the operator's carrier name points at. The value is
  # frozen into the DID document at mint time; changing it later requires a DID
  # update, which is why the storage token has to be present at CreateDPP.
  #
  # Returns { did:, doc_key:, rev_key:, rev_log: } (secrets in memory).
  def self.mint(product_id, endpoint_base: nil)
    require "oydid"

    base = endpoint_base.presence || self.endpoint_base
    content = {
      "service" => [{
        "type" => SERVICE_TYPE,
        "serviceEndpoint" => "#{base}/dpp/v1/dppsByProductId/#{CGI.escape(product_id.to_s)}"
      }]
    }

    # :location goes into the identifier itself (the "@<repo>" suffix that
    # normalize_did strips again for the default repo), :doc_location is the
    # repository document and log are published to. They are separate options
    # and both are needed: passing only :doc_location silently mints a DID
    # without its location suffix — resolvable only at the default repository.
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

  # Resolve a DID and return the serviceEndpoint of its DigitalProductPassport
  # service entry, or nil when the document carries none.
  #
  # Raises DidError when the DID does not resolve at all. oydid returns the
  # published document as { "doc" => <content>, "key" => ..., "log" => ... },
  # so the content this service minted sits one level in; older documents put
  # the service array at the top level, and both shapes are accepted.
  def self.service_endpoint(did)
    require "oydid"

    info = Timeout.timeout(RESOLVE_TIMEOUT) { Oydid.read(did.to_s, {}).first }
    raise DidError, "#{did} does not resolve" if info.nil? || info["error"].to_i != 0

    services = info.dig("doc", "doc", "service") || info.dig("doc", "service")
    entry = Array(services).find { |e| e.is_a?(Hash) && e["type"].to_s == SERVICE_TYPE }
    entry ||= Array(services).find { |e| e.is_a?(Hash) && e["serviceEndpoint"].present? }
    entry && entry["serviceEndpoint"].to_s.presence
  rescue Timeout::Error
    raise DidError, "#{did} did not resolve within #{RESOLVE_TIMEOUT}s"
  end

  # Check an identifier the client minted itself (Variante B) before the
  # passport is created with it.
  #
  # Two things have to hold. The DID must be live -- a passport under a DID
  # nobody can resolve is unreachable through the discovery path EN 18220:2026
  # describes. And its serviceEndpoint must name the host that will actually
  # hold the passport, because a reader who resolves the DID is sent there.
  #
  # Neither is repairable afterwards: this service holds no key for a DID it
  # did not mint, so it cannot perform the DID update that would move the
  # endpoint. Refusing at creation is the only point at which it is cheap.
  def self.assert_endpoint_host!(did, expected_base)
    endpoint = service_endpoint(did)
    if endpoint.blank?
      raise DidError, "#{did} carries no #{SERVICE_TYPE} service endpoint"
    end

    actual = uri_host(endpoint)
    wanted = uri_host(expected_base)
    return true if actual.present? && actual == wanted

    raise DidError,
          "digitalProductPassportId resolves to #{actual.presence || 'no host'}, " \
          "but this passport is served from #{wanted}"
  end

  def self.uri_host(value)
    URI.parse(value.to_s).host.to_s.downcase
  rescue URI::InvalidURIError
    ""
  end
  private_class_method :uri_host
end
