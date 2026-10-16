# frozen_string_literal: true

require "uri"
require "json"
require "base64"
require "digest"

# Client for a hosting pod of the data intermediary (dc-pod / pod-dpp).
#
# The pod is provisioned by the intermediary beforehand. Since the changeover
# described in docs/Delegation.md this service is handed no secret for it — what
# arrives in the X-DPP-Storage header is:
#
#   { "base_url": "https://dpp.go-data.at", "collection_id": "4",
#     "delegation": "eyJhbGciOiJFZERTQSIsInR5cCI6ImRwcC1kZWxlZ2F0aW9uK2p3dCJ9…" }
#
# The delegation is a JWT the economic operator signed with the document key of
# their own identity DID. It names this service in `sub`, this pod in `aud` and
# exactly one `product_id`. To turn it into an access token (§7) the service
# adds two statements of its own: a client assertion proving it is the service
# the delegation names, and a DPoP proof binding the token to its key.
#
# What this buys, compared with the client_secret it replaces: the artefact we
# store is useless to anyone else (it only works together with the private key
# of the service DID), it covers one passport rather than a whole collection,
# and the holder can revoke it at the pod without touching anything else.
#
# HTTP goes through OutboundHttp, which speaks HTTP/2 (EN 18216:2026 4).
class PodStorage
  # Pod failures are mapped onto the generic status codes of EN 18222:2026
  # (Table 15); docs/Delegation.md §15 fixes the mapping for the OAuth errors.
  class Error < StandardError
    attr_reader :status_code

    def initialize(message, status_code: "ServerErrorBadGateway")
      super(message)
      @status_code = status_code
    end
  end

  class ConfigError < Error
    def initialize(message)
      super(message, status_code: "ClientErrorBadRequest")
    end
  end

  # The delegation itself is not acceptable — wrong service, wrong pod, expired,
  # or an operation it does not cover. +status_code+ carries the §15 answer.
  class DelegationError < Error; end

  # The pod refused an access token at the resource (401 invalid_token). The
  # token is dropped and fetched once more; only if that one is refused too
  # does this reach the client, as ClientNotAuthorized.
  class TokenRejected < DelegationError
    def initialize(message)
      super(message, status_code: "ClientNotAuthorized")
    end
  end

  # One repeat after a refused token per incoming request, however many pod
  # requests that request makes. Rails resets it around every request.
  class TokenRetry < ActiveSupport::CurrentAttributes
    attribute :spent

    def self.take!
      return false if spent

      self.spent = true
    end
  end

  # No length constraint applies to this value. Since the carrier redesign the
  # UPI is the product identifier under a host of the operator's own (see
  # ProductIdentifier), while this base_url is the custodian's own address and
  # never reaches a carrier.

  OPEN_TIMEOUT = Integer(ENV.fetch("POD_OPEN_TIMEOUT", 5))
  READ_TIMEOUT = Integer(ENV.fetch("POD_READ_TIMEOUT", 15))

  # §7: no refresh token. A short access token is cheap because it can always be
  # re-fetched with the same delegation.
  DEFAULT_TOKEN_TTL = 600

  # §15, seen from this service: the pod deliberately does not say *why* a grant
  # failed, so invalid_grant covers both "expired or revoked" and "not the
  # controller of this collection". It becomes 401 here; the pod's log is where
  # the distinction lives.
  OAUTH_ERROR_STATUS = {
    "invalid_grant"       => "ClientNotAuthorized",
    "invalid_client"      => "ClientNotAuthorized",
    "invalid_dpop_proof"  => "ClientNotAuthorized",
    "invalid_token"       => "ClientNotAuthorized",
    "insufficient_scope"  => "ClientForbidden"
  }.freeze

  # The two cards of a passport (PassportSplit). One write delegation covers
  # both.
  PUBLIC_CARD     = "DigitalProductPassport"
  CONTROLLED_CARD = "DigitalProductPassportControlled"

  # What the pod says when it refuses a card with 409, and what the client is
  # told instead. Both are refusals of the passport as a whole, not errors of
  # this service.
  CONFLICTS = {
    "passport identifier is held by another collection" =>
      "The passport identifier or the product identifier is already held by a collection " \
      "of another economic operator at this custodian",
    "passport identifiers do not match the other card of this passport" =>
      "A card in this collection carries the same product identifier under another passport " \
      "identifier, or the other way round"
  }.freeze

  attr_reader :base_url, :collection_id, :delegation, :delegation_claims

  # --- construction ----------------------------------------------------------

  # From the X-DPP-Storage header. Accepts the JSON object of §9 directly, or
  # the same object base64url-encoded for clients that would rather not put
  # braces and quotes into a header value.
  def self.from_header(raw, verify: true)
    raise ConfigError, "Missing storage configuration" if raw.blank?

    payload = parse_header(raw)
    raise ConfigError, "X-DPP-Storage is not a JSON object" unless payload.is_a?(Hash)

    from_hash(payload, verify: verify)
  end

  def self.parse_header(raw)
    text = raw.to_s.strip
    return JSON.parse(text) if text.start_with?("{")

    JSON.parse(Base64.urlsafe_decode64(text + ("=" * ((4 - (text.length % 4)) % 4))))
  rescue JSON::ParserError, ArgumentError => e
    raise ConfigError, "X-DPP-Storage is neither JSON nor base64url JSON (#{e.class})"
  end
  private_class_method :parse_header

  def self.from_hash(payload, verify: true)
    payload = (payload || {}).with_indifferent_access
    new(base_url:      payload[:base_url],
        collection_id: payload[:collection_id],
        delegation:    payload[:delegation],
        verify:        verify)
  end

  # From what was stored on the DPP. The delegation is kept in the clear (§9):
  # without the private key of the service DID it is not usable by anyone, so
  # there is nothing left to encrypt.
  #
  # The signature is not re-checked on every read — it was checked when the
  # delegation arrived, and an attacker who can rewrite our own database has
  # better options than forging a delegation. What is still checked, on every
  # use, is that it has not expired and that it covers the operation.
  def self.for(dpp)
    return nil unless dpp.pod?

    if dpp.storage_delegation.blank?
      raise ConfigError,
            "No delegation stored for this passport — it predates the delegation " \
            "changeover and has to be created again (docs/Delegation.md §14)"
    end

    new(base_url:      dpp.storage_base_url,
        collection_id: dpp.storage_collection_id,
        delegation:    dpp.storage_delegation,
        verify:        false)
  end

  def initialize(base_url:, collection_id:, delegation:, verify: true)
    @base_url      = base_url.to_s.strip.chomp("/")
    @collection_id = collection_id.to_s.strip
    @delegation    = delegation.to_s.strip
    validate!
    @delegation_claims = verify ? verify_delegation! : Delegation.peek(@delegation)
    raise ConfigError, "delegation is not a readable JWT" if @delegation_claims.nil?
  end

  # What gets stored on the DPP. No secret in here — that is the point of §9.
  def storage_delegation
    delegation
  end

  # Does the stored delegation still permit +operation+ ("create", "update",
  # "delete")? Checked before the request so the service fails on its own terms
  # instead of at the pod.
  def covers?(operation)
    Delegation.covers?(delegation_claims, operation)
  end

  # §15: a mandate that has run out is ClientNotAuthorized, one that never
  # named the operation is ClientForbidden.
  def ensure_covers!(operation)
    return true if covers?(operation)

    if Array(delegation_claims["act"]).map(&:to_s).include?(operation.to_s)
      raise DelegationError.new("the delegation for this passport has expired",
                                status_code: "ClientNotAuthorized")
    end

    raise DelegationError.new(
      "the delegation for this passport does not cover #{operation}",
      status_code: "ClientForbidden"
    )
  end

  # Does the delegation name the passport it is being used for? D2 makes a
  # delegation a statement about one object, so the name of that object is part
  # of the mandate and has to match the passport the request is about. The pod
  # would catch a mismatch too, but only at the first write and with a bare
  # OAuth code -- and by then a DID may already have been minted.
  def covers_product?(product_id)
    delegation_claims["product_id"].to_s == product_id.to_s
  end

  def ensure_product!(product_id)
    return true if covers_product?(product_id)

    raise DelegationError.new(
      "the delegation is for product #{delegation_claims['product_id'].inspect}, " \
      "not #{product_id.to_s.inspect}",
      status_code: "ClientForbidden"
    )
  end

  # --- object lifecycle ------------------------------------------------------

  # Creates the index card through which pod-dpp finds the passport again,
  # the public one or the controlled one. Returns the object id.
  def create_object(dpp, type: PUBLIC_CARD)
    ensure_covers!("create")
    body = {
      "collection-id"            => numeric_collection_id,
      "type"                     => type,
      "digitalProductPassportId" => dpp.dpp_id,
      "uniqueProductIdentifier"  => dpp.product_id,
      # Host-independent lookup key: it is what lets this one store answer for
      # every operator hostname pointed at it by CNAME (docs/Identifiers.md).
      "product_key"              => dpp.product_key
    }
    response = begin
      request(:post, "/object", body: body)
    rescue DelegationError => e
      raise e unless type == CONTROLLED_CARD && e.status_code == "ClientForbidden"

      raise DelegationError.new("the delegation does not cover the controlled card of this passport " \
                                "(#{e.message})", status_code: "ClientForbidden")
    end
    id = response["object-id"] || response[:"object-id"]
    raise Error, "Pod did not return an object-id" if id.blank?

    id.to_s
  end

  # Writes the DPP document as the payload. Every change creates a new payload
  # row in the pod; the previous one stays retrievable under its DRI — that is
  # the version history of EN 18221:2026.
  def write_payload(object_id, document)
    ensure_covers!("update")
    request(:put, "/object/#{object_id}/write", body: document)
    true
  end

  # Soft delete: the archived versions survive (EN 18221:2026).
  def delete_object(object_id)
    ensure_covers!("delete")
    request(:delete, "/object/#{object_id}")
    true
  end

  # The public part of a passport is read without a token, through
  # PodStorage::PublicReader. The controlled card is read here, with the token
  # of the write delegation, and only to prepare a write: its values are
  # needed to apply a change to the whole passport. Raises Error with
  # ClientErrorResourceNotFound when the object is gone.
  def read_object(object_id)
    ensure_covers!("update")
    document = request(:get, "/object/#{object_id}/read")
    raise Error, "Pod #{base_url} answered GET /object/#{object_id}/read with something other than a JSON object" \
      unless document.is_a?(Hash)

    document
  end

  # Finding the controlled card without its object id needs the object list
  # and the index cards, which a write delegation may not read
  # (docs/Delegation.md D4). That is done under the read grant of this
  # service: PodStorage::ProtectedReader.

  # --- token (§7) ------------------------------------------------------------

  # Access token, cached until shortly before it expires. §7: no refresh token —
  # when it runs out, the same delegation fetches a new one.
  def token
    cached = self.class.token_cache_get(token_cache_key)
    return cached if cached

    response = fetch_token
    access = response["access_token"].to_s
    if access.empty?
      raise Error.new("Pod returned no access_token", status_code: "ClientNotAuthorized")
    end

    ttl = response["expires_in"].to_i
    ttl = DEFAULT_TOKEN_TTL if ttl <= 0
    self.class.token_cache_put(token_cache_key, access, ttl)
    access
  end

  # Checks reachability and that the delegation is actually redeemable, before
  # anything permanent happens — in particular before a DID is minted.
  def reachable!
    token
    true
  end

  class << self
    # The fields of an index card or its meta, wherever the pod nests them.
    def card_fields(answer)
      return {} unless answer.is_a?(Hash)

      %w[item data meta].each do |key|
        nested = answer[key]
        return nested if nested.is_a?(Hash) && (nested.key?("type") || nested.key?("updated-at"))
      end
      answer
    end

    def token_cache_get(key)
      mutex.synchronize do
        entry = cache[key]
        next nil if entry.nil?
        next nil if entry[:expires_at] <= Time.now.utc

        entry[:token]
      end
    end

    def token_cache_put(key, token, ttl_seconds)
      mutex.synchronize do
        # 60 s of headroom so no request starts with a token that is about to
        # expire mid-flight.
        cache[key] = { token: token,
                       expires_at: Time.now.utc + [ttl_seconds - 60, 30].max }
      end
    end

    def token_cache_delete(key)
      mutex.synchronize { cache.delete(key) }
    end

    def reset_token_cache!
      mutex.synchronize { cache.clear }
    end

    private

    def cache = (@cache ||= {})
    def mutex = (@mutex ||= Mutex.new)
  end

  private

  # §5 and §8, as far as this side can check it: a delegation naming another
  # service, another pod or another collection is not ours to keep. Storing it
  # would only move the failure to the first token request, where the pod's log
  # would carry the blame for our mistake.
  def verify_delegation!
    Delegation.verify!(delegation, audience: base_url, collection_id: collection_id)
  rescue Delegation::Invalid => e
    raise DelegationError.new(
      "delegation refused: #{e.message}",
      status_code: OAUTH_ERROR_STATUS.fetch(e.code, "ClientNotAuthorized")
    )
  rescue ServiceDid::NotConfigured => e
    raise ConfigError, "this deployment cannot accept delegations: #{e.message}"
  end

  def token_endpoint
    "#{base_url}/oauth/token"
  end

  def token_cache_key
    [base_url, delegation_claims["jti"]]
  end

  def fetch_token
    proof = Delegation.dpop_proof(htm: "POST", htu: token_endpoint)
    form  = {
      "grant_type"            => "urn:ietf:params:oauth:grant-type:jwt-bearer",
      "assertion"             => delegation,
      "client_assertion_type" => "urn:ietf:params:oauth:client-assertion-type:jwt-bearer",
      "client_assertion"      => Delegation.client_assertion(token_endpoint)
    }

    perform(:post, "/oauth/token",
            { "Accept" => "application/json",
              "Content-Type" => "application/x-www-form-urlencoded",
              "DPoP" => proof },
            URI.encode_www_form(form))
  end

  def validate!
    raise ConfigError, "storage configuration: base_url is required"      if base_url.empty?
    raise ConfigError, "storage configuration: collection_id is required" if collection_id.empty?
    raise ConfigError, "storage configuration: delegation is required"    if delegation.empty?

    unless base_url.start_with?("https://")
      raise ConfigError, "storage configuration: base_url must use https (EN 18216:2026 §6.2)"
    end

    URI.parse(base_url)
  rescue URI::InvalidURIError
    raise ConfigError, "storage configuration: base_url is not a valid URL"
  end

  # dc-pod expects the collection id numerically.
  def numeric_collection_id
    Integer(collection_id)
  rescue ArgumentError, TypeError
    collection_id
  end

  # A request to the resource with the delegated token.
  #
  # A token the pod refuses with 401 invalid_token -- expired early, or
  # withdrawn on its own -- is replaced once and the request repeated with a
  # fresh proof. Whether the delegation still holds is then decided at the token
  # endpoint, where invalid_grant is final and is not repeated.
  def request(method, path, body: nil)
    retried = false
    begin
      authorized_request(method, path, body)
    rescue TokenRejected
      raise if retried || !TokenRetry.take!

      retried = true
      Rails.logger.info("[pod] #{method.to_s.upcase} #{path}: token refused, fetching a new one " \
                        "(collection #{collection_id}, delegation #{delegation_claims['jti']})")
      retry
    end
  end

  def authorized_request(method, path, body)
    headers = { "Accept" => "application/json" }
    headers["Content-Type"] = "application/json" unless body.nil?

    access = token
    # RFC 9449: a DPoP-bound token travels in an "Authorization: DPoP" header,
    # and every request carries its own proof over this method and this URL.
    # `ath` binds the proof to the token, so a proof captured from one request
    # cannot be replayed with a different token.
    headers["Authorization"] = "DPoP #{access}"
    headers["DPoP"] = Delegation.dpop_proof(htm: method.to_s.upcase,
                                            htu: "#{base_url}#{path.split('?').first}",
                                            ath: access)

    perform(method, path, headers, body.nil? ? nil : JSON.generate(body))
  end

  def perform(method, path, headers, payload)
    response = OutboundHttp.request(method, "#{base_url}#{path}",
                                    headers: headers, body: payload,
                                    open_timeout: OPEN_TIMEOUT, read_timeout: READ_TIMEOUT)

    handle(response, method, path)
  rescue OutboundHttp::TimeoutError
    raise Error, "Pod #{base_url} timed out on #{method.to_s.upcase} #{path}"
  rescue OutboundHttp::ConnectionError => e
    raise Error, "Pod #{base_url} unreachable (#{e.message})"
  end

  def handle(response, method, path)
    parsed = begin
      response.body.to_s.empty? ? {} : JSON.parse(response.body)
    rescue JSON::ParserError
      {}
    end

    case response.code.to_i
    when 200, 201, 204 then parsed
    when 400, 401, 403
      # Only the token of this delegation is dropped; the next use fetches a
      # new one.
      self.class.token_cache_delete(token_cache_key)
      if response.code.to_i == 401 && parsed["error"].to_s == "invalid_token" && path != "/oauth/token"
        raise TokenRejected, "Pod refused the access token (401, invalid_token)"
      end

      raise oauth_error(parsed, response, method, path)
    when 404
      raise Error.new("Pod: not found (#{method.to_s.upcase} #{path})",
                      status_code: "ClientErrorResourceNotFound")
    when 409
      reason = parsed.is_a?(Hash) ? parsed["error"].to_s : ""
      raise Error.new(CONFLICTS.fetch(reason) { "The custodian refused the card (409#{reason.empty? ? '' : ", #{reason}"})" },
                      status_code: "ClientResourceConflict")
    else
      detail = parsed["error"] || parsed["message"] || response.message
      raise Error, "Pod #{base_url} returned #{response.code} on " \
                   "#{method.to_s.upcase} #{path}: #{detail}"
    end
  end

  # The pod answers a refused grant with an OAuth error code (§15). It says
  # nothing about *which* rule failed — deliberately, because a precise message
  # is a manual for forging the next attempt — so the log line here records what
  # we asked for, and the client gets the mapped status code.
  def oauth_error(parsed, response, method, path)
    code = parsed["error"].to_s
    status = OAUTH_ERROR_STATUS.fetch(code, "ClientNotAuthorized")
    Rails.logger.info(
      "[pod] #{method.to_s.upcase} #{path} refused with #{response.code} #{code.presence || 'unspecified'} " \
      "(collection #{collection_id}, delegation #{delegation_claims['jti']})"
    )

    klass = code.empty? ? Error : DelegationError
    klass.new("Pod refused the request (#{response.code}#{code.empty? ? '' : ", #{code}"})",
              status_code: status)
  end
end
