# frozen_string_literal: true

require "uri"
require "json"
require "digest"
require "erb"

class PodStorage
  # This service as the protected reader of a DPP hosting collection
  # (docs/Delegation.md §3): the statutory reader the intermediary enters when
  # the hosting agreement is signed, and which the economic operator can
  # neither remove nor revoke.
  #
  # It reads under a read grant it signs itself with the reader DID of the pod
  # (ReaderDid), not under a mandate of the economic operator, so the access
  # does not end when a write delegation runs out, when the custodian stops
  # taking writes, or when the controller of the collection changes.
  #
  #   header  alg EdDSA, typ pod-read-delegation+jwt, kid <reader DID>#key-doc
  #   claims  iss = sub = reader DID, aud = the pod, collections = [id],
  #           act = ["read"], purpose, iat, nbf, exp, jti
  #
  # The grant is not stored anywhere. It is signed again whenever it is needed,
  # from the start of the current 30-day window: iat = nbf = window start,
  # exp = window start + 90 days. Ed25519 signatures are deterministic, so every
  # process and every replica signs the same grant, byte for byte, under the
  # same name (jti) for the whole window, and a grant in use has at least 60
  # days left. The name changes with the window; the custodian's disclosure
  # shows one grant per window.
  #
  # Client assertion and DPoP proofs are signed with the same key, the document
  # key of the reader DID: the custodian binds the token to the key of the
  # client assertion. The token lasts min(600 s, exp - now) and is fetched
  # again 60 s before it runs out.
  #
  # Refusals: 400 invalid_grant at the token endpoint means the custodian does
  # not accept this service as reader of the collection -- the reader was never
  # entered or has been removed -- and is final (NotAdmitted). 401 invalid_token
  # at the resource drops the token and fetches one new one.
  #
  # Every GET under the read grant goes into the access log (AccessLog), with
  # the passport it was made for, so that the log has one entry for each read
  # the custodian served this service. The token request is not a read.
  class ProtectedReader
    WINDOW   = 30 * 86_400
    LIFETIME = 90 * 86_400
    PURPOSE  = "espr_legal_access"
    TYP      = "pod-read-delegation+jwt"

    # No reader DID is configured for this pod.
    class NoReader < Error; end

    # The custodian does not accept this service as reader of the collection.
    class NotAdmitted < Error; end

    attr_reader :base_url, :collection_id, :reader, :dpp_id

    # +dpp_id+: the passport the reads are made for, for the access log.
    def self.for(base_url, collection_id, dpp_id: nil)
      reader = ReaderDid.for_pod(base_url)
      raise NoReader, "no reader DID is configured for the pod #{base_url}" if reader.nil?

      new(reader, collection_id, dpp_id: dpp_id)
    end

    def initialize(reader, collection_id, dpp_id: nil)
      @reader        = reader
      @base_url      = reader.pod
      @collection_id = collection_id.to_s
      @dpp_id        = dpp_id
    end

    # The read grant for the window +now+ falls in.
    def grant(now: Time.now.to_i)
      start = (now / WINDOW) * WINDOW
      Delegation.sign(reader.signing_key, typ: TYP, kid: "#{reader.did}#key-doc", payload: {
                        "iss" => reader.did, "sub" => reader.did, "aud" => base_url,
                        "collections" => [collection_id], "act" => ["read"], "purpose" => PURPOSE,
                        "iat" => start, "nbf" => start, "exp" => start + LIFETIME,
                        "jti" => grant_name(start)
                      })
    end

    def grant_name(start = (Time.now.to_i / WINDOW) * WINDOW)
      "dpp-service-read-#{collection_id}-#{Time.at(start).utc.strftime('%Y%m%d')}"
    end

    # A token under the read grant. Returns the token and what the custodian
    # said about it (+scope+, +expires_in+); neither is ever logged here.
    def token
      cached = PodStorage.token_cache_get(cache_key)
      return cached if cached

      answer = fetch_token
      access = answer["access_token"].to_s
      raise Error, "the custodian at #{base_url} issued no read token" if access.empty?

      @last_grant_answer = answer.slice("scope", "expires_in", "token_type")
      ttl = answer["expires_in"].to_i
      PodStorage.token_cache_put(cache_key, access, ttl.positive? ? ttl : DEFAULT_TOKEN_TTL)
      access
    end

    # scope, expires_in and token_type of the last token fetched, for the
    # measurement; never the token.
    attr_reader :last_grant_answer

    def read_object(object_id)
      document = get("/object/#{object_id}/read")
      raise Error, "the custodian answered /object/#{object_id}/read with something other than a JSON object" \
        unless document.is_a?(Hash)

      document
    end

    # The versions of the controlled card of +dpp_id+, oldest first, each
    # { "version", "timestamp", "dri" }; nil when the custodian has none for
    # it or does not serve them.
    def controlled_versions(dpp_id)
      answer = get("/dpp/v1/controlled/dpps/#{ERB::Util.url_encode(dpp_id.to_s)}/versions")
      Array(answer.is_a?(Hash) ? answer["versions"] : nil).sort_by { |v| v["version"].to_i }
    rescue Error => e
      raise e unless e.status_code == "ClientErrorResourceNotFound"

      nil
    end

    # The controlled payload of +dpp_id+ as it stood at +time+, as stored; nil
    # when the custodian has none for that time or does not serve versions of
    # controlled cards.
    def controlled_at(dpp_id, time)
      document = get("/dpp/v1/controlled/dppsByIdAndDate/#{ERB::Util.url_encode(dpp_id.to_s)}" \
                     "?date=#{ERB::Util.url_encode(time.utc.iso8601)}")
      document.is_a?(Hash) ? document : nil
    rescue Error => e
      raise e unless e.status_code == "ClientErrorResourceNotFound"

      nil
    end

    def object_ids
      Array(get("/collection/#{collection_id}/objects?page=all")).filter_map do |entry|
        (entry.is_a?(Hash) ? entry["object-id"] || entry["id"] : entry)&.to_s.presence
      end
    end

    def card(object_id) = PodStorage.card_fields(get("/object/#{object_id}"))

    def meta(object_id) = PodStorage.card_fields(get("/object/#{object_id}/meta"))

    # The controlled card of +dpp_id+, through the object list (deleted
    # objects are left out) and card by card; of two the more recently changed
    # one. nil if the collection holds none.
    def locate_controlled_card(dpp_id)
      hits = object_ids.select do |id|
        fields = card(id)
        fields["type"] == CONTROLLED_CARD && fields["digitalProductPassportId"] == dpp_id.to_s
      rescue Error => e
        raise e unless e.status_code == "ClientErrorResourceNotFound"

        false
      end
      return hits.first if hits.size <= 1

      hits.max_by { |id| meta(id)["updated-at"].to_s }
    end

    private

    def token_endpoint = "#{base_url}/oauth/token"

    def cache_key = ["read", base_url, collection_id, grant_name]

    def fetch_token
      form = {
        "grant_type"            => "urn:ietf:params:oauth:grant-type:jwt-bearer",
        "assertion"             => grant,
        "client_assertion_type" => "urn:ietf:params:oauth:client-assertion-type:jwt-bearer",
        "client_assertion"      => Delegation.client_assertion(token_endpoint, did: reader.did,
                                                                               key: reader.signing_key)
      }
      headers = { "Accept" => "application/json", "Content-Type" => "application/x-www-form-urlencoded",
                  "DPoP" => Delegation.dpop_proof(htm: "POST", htu: token_endpoint, key: reader.signing_key) }
      response = perform(:post, "/oauth/token", headers, URI.encode_www_form(form))
      parsed = parse(response)
      return parsed if response.code.to_i == 200

      refused_grant(response, parsed)
    end

    def refused_grant(response, parsed)
      code = parsed["error"].to_s
      Rails.logger.info("[reader] read grant for collection #{collection_id} at #{base_url} refused with " \
                        "#{response.code} #{code.presence || 'unspecified'} (grant #{grant_name})")
      if code == "invalid_grant"
        raise NotAdmitted, "the custodian at #{base_url} does not accept this service as protected reader " \
                           "of collection #{collection_id} (invalid_grant)"
      end

      raise Error, "the custodian at #{base_url} refused the read grant (#{response.code}" \
                   "#{code.empty? ? '' : ", #{code}"})"
    end

    # One new token after 401 invalid_token, then the answer stands.
    def get(path)
      retried = false
      begin
        authorized_get(path)
      rescue TokenRejected
        raise Error, "the custodian at #{base_url} refused a fresh read token as well" if retried

        retried = true
        retry
      end
    end

    def authorized_get(path)
      access = token
      headers = { "Accept" => "application/json", "Authorization" => "DPoP #{access}",
                  "DPoP" => Delegation.dpop_proof(htm: "GET", htu: "#{base_url}#{path.split('?').first}",
                                                  ath: access, key: reader.signing_key) }
      response = logged_get(path, headers)
      parsed = parse(response)
      case response.code.to_i
      when 200 then parsed
      when 401
        PodStorage.token_cache_delete(cache_key)
        raise TokenRejected, "read token refused (401)" if parsed.is_a?(Hash) && parsed["error"] == "invalid_token"

        raise Error, "the custodian at #{base_url} refused the read token (401)"
      when 404
        raise Error.new("not found at the custodian (GET #{path})", status_code: "ClientErrorResourceNotFound")
      else
        detail = parsed.is_a?(Hash) ? parsed["error"] : nil
        raise Error, "the custodian at #{base_url} answered #{response.code} on GET #{path}" \
                     "#{detail ? " (#{detail})" : ''}"
      end
    end

    def logged_get(path, headers)
      response = perform(:get, path, headers, nil)
      AccessLog.pod_read(dpp_id: dpp_id, base_url: base_url, path: path, status: response.code.to_i)
      response
    rescue Error
      AccessLog.pod_read(dpp_id: dpp_id, base_url: base_url, path: path, status: nil)
      raise
    end

    def perform(method, path, headers, body)
      OutboundHttp.request(method, "#{base_url}#{path}", headers: headers, body: body,
                                                         open_timeout: OPEN_TIMEOUT, read_timeout: READ_TIMEOUT)
    rescue OutboundHttp::TimeoutError
      raise Error, "the custodian at #{base_url} timed out on #{method.to_s.upcase} #{path}"
    rescue OutboundHttp::ConnectionError => e
      raise Error, "the custodian at #{base_url} is unreachable (#{e.message})"
    end

    def parse(response)
      response.body.to_s.empty? ? {} : JSON.parse(response.body)
    rescue JSON::ParserError
      {}
    end
  end
end
