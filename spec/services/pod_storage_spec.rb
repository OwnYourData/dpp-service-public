# frozen_string_literal: true

require "rails_helper"
require "digest"

# HTTP layer of the pod client. OutboundHttp is stubbed so the specs run without a
# network; what is checked is which requests the client builds and how it maps
# the pod's answers onto the generic status codes of EN 18222:2026 (Table 15) and
# the OAuth errors of docs/Delegation.md §15.
RSpec.describe PodStorage do
  let(:base_url)    { "https://dpp.go-data.at" }
  let(:holder)      { Ed25519::SigningKey.new(Digest::SHA256.digest("pod-storage-spec/holder")) }
  let(:service_key) { Ed25519::SigningKey.new(Digest::SHA256.digest("pod-storage-spec/service")) }
  let(:holder_did)  { "did:oyd:zHolderForPodStorageSpec" }
  let(:service_did) { "did:oyd:zServiceForPodStorageSpec" }

  # A delegation as the economic operator would sign it (§5).
  def delegation_jwt(overrides = {})
    now = Time.now.to_i
    payload = { "iss" => holder_did, "sub" => service_did, "aud" => base_url,
                "collection" => "4",
                "product_id" => "https://id.lumina.example/01/09520123456795",
                "act" => %w[create update delete], "purpose" => "dpp-hosting",
                "iat" => now, "nbf" => now, "exp" => now + (90 * 86_400),
                "jti" => "b2f1c9e4a7d05386" }.merge(overrides)
    Delegation.sign(holder, typ: Delegation::TYP_DELEGATION,
                            kid: "#{holder_did}#key-doc", payload: payload)
  end

  let(:delegation) { delegation_jwt }
  let(:config) { { base_url: base_url, collection_id: "4", delegation: delegation } }

  subject(:storage) { described_class.new(**config) }

  before do
    described_class.reset_token_cache!
    described_class::TokenRetry.reset
    allow(ServiceDid).to receive(:did).and_return(service_did)
    allow(ServiceDid).to receive(:signing_key).and_return(service_key)
    allow(DidTokenVerifier).to receive(:public_key_for).with(holder_did).and_return(holder.verify_key)
  end

  # Intercepts OutboundHttp and records the requests that were sent.
  def stub_pod(responses)
    requests = []
    queue = Array(responses).dup

    allow(OutboundHttp).to receive(:perform) do |req, **|
      requests << req
      spec = queue.size > 1 ? queue.shift : queue.first
      body = spec[:body].is_a?(String) ? spec[:body] : JSON.generate(spec[:body] || {})
      OutboundHttp::Response.new(code: spec[:status].to_s, body: body, message: "stubbed", version: "2.0")
    end
    requests
  end

  def token_response(expires_in: 600)
    { status: 200, body: { access_token: "pod-token", token_type: "DPoP", expires_in: expires_in } }
  end

  describe "validation of the storage configuration" do
    # No length rule. The identifier the carrier bears is the ProductID under a
    # host of the operator's own, and this base_url is the custodian's own
    # address, which never gets printed.
    it "accepts a base_url of any length, since it never reaches a carrier" do
      long = "https://#{'a' * 40}.example.org"
      expect { described_class.new(**config.merge(base_url: long, verify: false)) }
        .not_to raise_error
    end

    it "rejects plain http (EN 18216:2026 6.2 requires TLS)" do
      expect { described_class.new(**config.merge(base_url: "http://dpp.go-data.at")) }
        .to raise_error(described_class::ConfigError, /https/)
    end

    %i[base_url collection_id delegation].each do |field|
      it "rejects a configuration without #{field}" do
        expect { described_class.new(**config.merge(field => "")) }
          .to raise_error(described_class::ConfigError, /#{field}/)
      end
    end

    it "strips a trailing slash so paths do not double up" do
      expect(described_class.new(**config.merge(base_url: "#{base_url}/")).base_url).to eq(base_url)
    end

    it "maps a configuration error to ClientErrorBadRequest" do
      expect(described_class::ConfigError.new("nope").status_code).to eq("ClientErrorBadRequest")
    end
  end

  describe ".from_header" do
    it "reads the three fields out of the JSON object of §9" do
      parsed = described_class.from_header(
        { base_url: base_url, collection_id: "4", delegation: delegation }.to_json
      )

      expect(parsed.base_url).to eq(base_url)
      expect(parsed.collection_id).to eq("4")
      expect(parsed.storage_delegation).to eq(delegation)
    end

    it "also accepts the same object base64url-encoded" do
      raw = Base64.urlsafe_encode64(
        { base_url: base_url, collection_id: "4", delegation: delegation }.to_json, padding: false
      )

      expect(described_class.from_header(raw).base_url).to eq(base_url)
    end

    it "rejects a malformed header" do
      expect { described_class.from_header("not-json-at-all") }
        .to raise_error(described_class::ConfigError, /neither JSON nor base64url/)
    end

    it "rejects a missing header" do
      expect { described_class.from_header(nil) }
        .to raise_error(described_class::ConfigError, /Missing storage configuration/)
    end

    it "refuses a delegation addressed to another service" do
      error = nil
      begin
        described_class.from_header(
          { base_url: base_url, collection_id: "4",
            delegation: delegation_jwt("sub" => "did:oyd:zSomeoneElse") }.to_json
        )
      rescue described_class::DelegationError => e
        error = e
      end

      expect(error).to be_a(described_class::DelegationError)
      expect(error.status_code).to eq("ClientNotAuthorized")
    end

    it "refuses a delegation for a different collection than the header names" do
      expect {
        described_class.from_header(
          { base_url: base_url, collection_id: "9", delegation: delegation }.to_json
        )
      }.to raise_error(described_class::DelegationError, /collection/)
    end

    it "stores no secret — the delegation is all there is" do
      parsed = described_class.from_header(
        { base_url: base_url, collection_id: "4", delegation: delegation }.to_json
      )

      expect(parsed.storage_delegation).to eq(delegation)
      expect(parsed).not_to respond_to(:client_secret)
    end
  end

  describe ".for" do
    it "says plainly when a passport predates the changeover" do
      dpp = Dpp.new(storage_backend: "pod", storage_base_url: base_url,
                    storage_collection_id: "4", storage_delegation: nil)

      expect { described_class.for(dpp) }
        .to raise_error(described_class::ConfigError, /predates the delegation changeover/)
    end
  end

  describe "#covers?" do
    it "is true for an operation the delegation names" do
      expect(storage.covers?("update")).to be(true)
    end

    it "is false for one it does not" do
      limited = described_class.new(**config.merge(delegation: delegation_jwt("act" => ["create"])))

      expect(limited.covers?("delete")).to be(false)
    end

    it "refuses the write rather than letting the pod do it, with ClientForbidden" do
      limited = described_class.new(**config.merge(delegation: delegation_jwt("act" => ["create"])))

      expect { limited.write_payload("4711", {}) }
        .to raise_error(described_class::DelegationError) { |e|
          expect(e.status_code).to eq("ClientForbidden")
        }
    end
  end

  # §15: a mandate that has run out is a matter of authorisation, one that
  # never named the operation a matter of permission.
  describe "#ensure_covers!" do
    it "answers ClientNotAuthorized for a delegation that has expired" do
      past = Time.now.to_i - 3600
      expired = described_class.new(**config.merge(
        delegation: delegation_jwt("iat" => past - 86_400, "nbf" => past - 86_400, "exp" => past),
        verify: false
      ))

      expect { expired.ensure_covers!("update") }
        .to raise_error(described_class::DelegationError) { |e|
          expect(e.status_code).to eq("ClientNotAuthorized")
        }
    end

    it "answers ClientForbidden for an operation the delegation never named" do
      limited = described_class.new(**config.merge(delegation: delegation_jwt("act" => ["create"])))

      expect { limited.ensure_covers!("delete") }
        .to raise_error(described_class::DelegationError) { |e|
          expect(e.status_code).to eq("ClientForbidden")
        }
    end
  end

  # D2: one delegation names one passport. The name has to be the passport the
  # request is about, or the mandate is redeemable but not for this object.
  describe "#ensure_product!" do
    let(:named) { "https://id.lumina.example/01/09520123456795" }

    it "passes for the product the delegation names" do
      expect(storage.ensure_product!(named)).to be(true)
    end

    it "refuses another product with ClientForbidden" do
      expect { storage.ensure_product!("https://id.lumina.example/01/09520123456788") }
        .to raise_error(described_class::DelegationError) { |e|
          expect(e.status_code).to eq("ClientForbidden")
          expect(e.message).to include(named)
        }
    end

    it "refuses a blank product" do
      expect { storage.ensure_product!(nil) }
        .to raise_error(described_class::DelegationError)
    end
  end

  describe "#token" do
    it "presents the delegation, a client assertion and a DPoP proof (§7)" do
      requests = stub_pod([token_response])

      expect(storage.token).to eq("pod-token")

      req = requests.first
      expect(req.path).to eq("/oauth/token")
      expect(req.body).to include(
        "grant_type=#{CGI.escape('urn:ietf:params:oauth:grant-type:jwt-bearer')}",
        "client_assertion_type=#{CGI.escape('urn:ietf:params:oauth:client-assertion-type:jwt-bearer')}"
      )
      expect(req.body).to include("assertion=#{CGI.escape(delegation)}")

      proof = Delegation.peek(req["DPoP"])
      expect(proof["htm"]).to eq("POST")
      expect(proof["htu"]).to eq("#{base_url}/oauth/token")
      expect(proof).not_to have_key("ath")   # no access token exists yet
    end

    it "sends no client_secret, because there is none" do
      requests = stub_pod([token_response])
      storage.token

      expect(requests.first.body).not_to include("client_secret")
    end

    it "caches the token instead of asking again on every call" do
      requests = stub_pod([token_response])

      3.times { storage.token }
      expect(requests.size).to eq(1)
    end

    it "keys the cache by the delegation, so two mandates do not share a token" do
      stub_pod([token_response])
      storage.token

      expect(described_class.token_cache_get([base_url, "b2f1c9e4a7d05386"])).to eq("pod-token")
      expect(described_class.token_cache_get([base_url, "another-jti"])).to be_nil
    end

    it "does not reuse a token that is about to expire" do
      requests = stub_pod([token_response(expires_in: 10)])

      storage.token
      storage.token
      expect(requests.size).to be >= 1
    end

    it "reports a missing access_token as ClientNotAuthorized" do
      stub_pod([{ status: 200, body: {} }])

      expect { storage.token }
        .to raise_error(described_class::Error) { |e| expect(e.status_code).to eq("ClientNotAuthorized") }
    end
  end

  describe "#create_object" do
    let(:dpp) do
      Dpp.new(dpp_id: "did:oyd:zX", product_id: "https://id.example/01/1",
              dpp_schema_version: "EN 18223:2026",
              economic_operator_id: "did:oyd:zQmPPwHJK1NHBz3BS89StWsfrH4pzkyqwJiK94zVj25wXUS",
              last_update: Time.now.utc)
    end

    it "posts the card that pod-dpp looks the passport up by" do
      requests = stub_pod([token_response, { status: 200, body: { "object-id" => 4711 } }])

      expect(storage.create_object(dpp)).to eq("4711")

      card = JSON.parse(requests.last.body)
      expect(requests.last.path).to eq("/object")
      expect(card).to include(
        "collection-id"            => 4,          # numeric, as dc-pod expects
        "type"                     => "DigitalProductPassport",
        "digitalProductPassportId" => "did:oyd:zX",
        "uniqueProductIdentifier"                => "https://id.example/01/1"
      )
      expect(card).not_to have_key("schema")      # else dc-pod tries a SOyA label
    end

    it "sends the token as DPoP-bound, with a proof over this very request" do
      requests = stub_pod([token_response, { status: 200, body: { "object-id" => 1 } }])

      storage.create_object(dpp)

      expect(requests.last["Authorization"]).to eq("DPoP pod-token")
      proof = Delegation.peek(requests.last["DPoP"])
      expect(proof["htm"]).to eq("POST")
      expect(proof["htu"]).to eq("#{base_url}/object")
      # RFC 9449 §7.1: the proof is bound to the token it accompanies.
      expect(proof["ath"]).to eq(Delegation.b64u(Digest::SHA256.digest("pod-token")))
    end

    it "fails loudly when the pod returns no object-id" do
      stub_pod([token_response, { status: 200, body: {} }])

      expect { storage.create_object(dpp) }.to raise_error(described_class::Error, /object-id/)
    end
  end

  describe "#write_payload" do
    it "puts the DPP document to the write endpoint" do
      requests = stub_pod([token_response, { status: 200, body: {} }])

      storage.write_payload("4711", { "uniqueProductIdentifier" => "https://id.example/01/1" })

      expect(requests.last.path).to eq("/object/4711/write")
      expect(JSON.parse(requests.last.body)).to eq("uniqueProductIdentifier" => "https://id.example/01/1")
    end
  end

  describe "error mapping (EN 18222:2026 Tables 12-15, docs/Delegation.md §15)" do
    {
      404 => "ClientErrorResourceNotFound",
      500 => "ServerErrorBadGateway",
      502 => "ServerErrorBadGateway"
    }.each do |http_status, generic|
      it "maps HTTP #{http_status} to #{generic}" do
        stub_pod([token_response, { status: http_status, body: { "error" => "boom" } }])

        expect { storage.write_payload("4711", {}) }
          .to raise_error(described_class::Error) { |e| expect(e.status_code).to eq(generic) }
      end
    end

    {
      "invalid_grant"      => "ClientNotAuthorized",
      "invalid_dpop_proof" => "ClientNotAuthorized",
      "insufficient_scope" => "ClientForbidden"
    }.each do |oauth_error, generic|
      it "maps the OAuth error #{oauth_error} to #{generic}" do
        stub_pod([token_response, { status: 400, body: { "error" => oauth_error } }])

        expect { storage.write_payload("4711", {}) }
          .to raise_error(described_class::DelegationError) { |e|
            expect(e.status_code).to eq(generic)
          }
      end
    end

    it "does not repeat the pod's reason to the client" do
      stub_pod([token_response,
                { status: 400, body: { "error" => "invalid_grant",
                                       "error_description" => "jti on the denylist" } }])

      expect { storage.write_payload("4711", {}) }
        .to raise_error(described_class::Error) { |e|
          expect(e.message).not_to include("denylist")
        }
    end

    it "drops the cached token when the pod rejects it" do
      stub_pod([token_response, { status: 401, body: {} }])

      expect { storage.write_payload("4711", {}) }.to raise_error(described_class::Error)
      expect(described_class.token_cache_get([base_url, "b2f1c9e4a7d05386"])).to be_nil
    end

    it "drops only the token of this delegation, not those of others" do
      described_class.token_cache_put([base_url, "another-jti"], "other-token", 600)
      stub_pod([token_response, { status: 401, body: {} }])

      expect { storage.write_payload("4711", {}) }.to raise_error(described_class::Error)
      expect(described_class.token_cache_get([base_url, "another-jti"])).to eq("other-token")
    end

    it "reports an unreachable pod as a bad gateway" do
      allow(OutboundHttp).to receive(:perform)
        .and_raise(OutboundHttp::ConnectionError, "Errno::ECONNREFUSED: Connection refused")

      expect { storage.token }
        .to raise_error(described_class::Error) { |e| expect(e.status_code).to eq("ServerErrorBadGateway") }
    end
  end

  # The pod can refuse an access token it issued itself -- expired early, or
  # withdrawn on its own. One new token, one repeat; whether the mandate still
  # holds is then for the token endpoint to say, and invalid_grant there is final.
  describe "a token refused at the resource (401 invalid_token)" do
    let(:refused) { { status: 401, body: { "error" => "invalid_token" } } }

    def token_response_with(access)
      { status: 200, body: { access_token: access, token_type: "DPoP", expires_in: 600 } }
    end

    def token_requests(requests) = requests.count { |r| r.path == "/oauth/token" }

    it "fetches one new token and repeats the request with it" do
      requests = stub_pod([token_response_with("first"), refused,
                           token_response_with("second"), { status: 200, body: {} }])

      expect(storage.write_payload("4711", { "a" => 1 })).to be(true)

      expect(requests.map(&:path)).to eq(["/oauth/token", "/object/4711/write",
                                          "/oauth/token", "/object/4711/write"])
      expect(requests.last["Authorization"]).to eq("DPoP second")
      expect(requests.last.body).to eq(requests[1].body)
    end

    it "sends a fresh DPoP proof with the repeat, bound to the new token" do
      requests = stub_pod([token_response_with("first"), refused,
                           token_response_with("second"), { status: 200, body: {} }])

      storage.write_payload("4711", {})

      first  = Delegation.peek(requests[1]["DPoP"])
      repeat = Delegation.peek(requests[3]["DPoP"])
      expect(repeat["jti"]).not_to eq(first["jti"])
      expect(repeat["ath"]).to eq(Delegation.b64u(Digest::SHA256.digest("second")))
    end

    it "gives up after the second refusal, with ClientNotAuthorized" do
      requests = stub_pod([token_response_with("first"), refused,
                           token_response_with("second"), refused])

      expect { storage.write_payload("4711", {}) }
        .to raise_error(described_class::DelegationError) { |e|
          expect(e.status_code).to eq("ClientNotAuthorized")
        }
      expect(requests.size).to eq(4)
      expect(token_requests(requests)).to eq(2)
    end

    it "does not repeat once the token endpoint answers invalid_grant" do
      requests = stub_pod([token_response_with("first"), refused,
                           { status: 400, body: { "error" => "invalid_grant" } }])

      expect { storage.write_payload("4711", {}) }
        .to raise_error(described_class::DelegationError) { |e|
          expect(e.status_code).to eq("ClientNotAuthorized")
        }
      expect(requests.map(&:path)).to eq(["/oauth/token", "/object/4711/write", "/oauth/token"])
    end

    it "treats invalid_grant at the first token request as final" do
      requests = stub_pod([{ status: 400, body: { "error" => "invalid_grant" } }])

      expect { storage.write_payload("4711", {}) }.to raise_error(described_class::DelegationError)
      expect(requests.size).to eq(1)
    end

    it "does not repeat on a 401 that is not invalid_token" do
      requests = stub_pod([token_response, { status: 401, body: { "error" => "invalid_dpop_proof" } }])

      expect { storage.write_payload("4711", {}) }.to raise_error(described_class::DelegationError)
      expect(requests.size).to eq(2)
    end

    # Several pod requests can serve one incoming request (delete: write the
    # final state, then remove the object). The repeat is granted once for all
    # of them together.
    it "fetches at most one additional token per incoming request" do
      requests = stub_pod([token_response_with("first"), refused,
                           token_response_with("second"), { status: 200, body: {} },
                           refused])

      storage.write_payload("4711", {})
      expect { storage.delete_object("4711") }
        .to raise_error(described_class::DelegationError) { |e|
          expect(e.status_code).to eq("ClientNotAuthorized")
        }
      expect(token_requests(requests)).to eq(2)
    end

    it "grants the repeat again for the next incoming request" do
      stub_pod([token_response_with("first"), refused,
                token_response_with("second"), { status: 200, body: {} }])
      storage.write_payload("4711", {})

      described_class::TokenRetry.reset
      requests = stub_pod([refused, token_response_with("third"), { status: 200, body: {} }])

      expect(storage.write_payload("4711", {})).to be(true)
      expect(requests.last["Authorization"]).to eq("DPoP third")
    end
  end

  describe "the controlled card" do
    let(:product) { "https://dpp.oydapp.eu/01/09520123456795/21/000777" }
    let(:dpp) { Dpp.new(dpp_id: "did:oyd:zQmC", product_id: product, product_key: "/01/09520123456795/21/000777") }

    def answer(code, body)
      OutboundHttp::Response.new(code: code.to_s, body: body.is_a?(String) ? body : JSON.generate(body),
                                 message: "stubbed", version: "2.0")
    end

    def stub_routes(routes)
      seen = []
      allow(OutboundHttp).to receive(:perform) do |req, **|
        seen << "#{req.method.to_s.upcase} #{req.path}"
        next answer(200, { "access_token" => "t", "token_type" => "DPoP", "expires_in" => 600 }) if req.path == "/oauth/token"

        code, body = routes.fetch("#{req.method.to_s.upcase} #{req.path}") { raise "unexpected #{req.method} #{req.path}" }
        answer(code, body)
      end
      seen
    end

    subject(:storage) do
      described_class.new(base_url: "https://dpp-staging.go-data.at", collection_id: "4",
                          delegation: delegation_jwt, verify: false)
    end

    it "is created with its own type" do
      body = nil
      allow(OutboundHttp).to receive(:perform) do |req, **|
        next answer(200, { "access_token" => "t", "expires_in" => 600 }) if req.path == "/oauth/token"

        body = JSON.parse(req.body)
        answer(200, { "object-id" => 7 })
      end

      expect(storage.create_object(dpp, type: described_class::CONTROLLED_CARD)).to eq("7")
      expect(body).to include("type" => "DigitalProductPassportControlled", "digitalProductPassportId" => "did:oyd:zQmC")
    end

    it "says so when the delegation does not cover it" do
      stub_routes("POST /object" => [403, { "error" => "insufficient_scope" }])

      expect { storage.create_object(dpp, type: described_class::CONTROLLED_CARD) }
        .to raise_error(described_class::DelegationError, /does not cover the controlled card/) { |e|
          expect(e.status_code).to eq("ClientForbidden")
        }
    end

    {
      "passport identifier is held by another collection" => /another economic operator/,
      "passport identifiers do not match the other card of this passport" => /another passport/,
      "something else" => /409, something else/
    }.each do |reason, text|
      it "maps 409 #{reason.inspect} to ClientResourceConflict" do
        stub_routes("POST /object" => [409, { "error" => reason }])

        expect { storage.create_object(dpp) }
          .to raise_error(described_class::Error, text) { |e| expect(e.status_code).to eq("ClientResourceConflict") }
      end
    end

    it "is read with the write delegation" do
      seen = stub_routes("GET /object/7/read" => [200, { "elements" => [] }])

      expect(storage.read_object("7")).to eq("elements" => [])
      expect(seen).to include("GET /object/7/read")
    end
  end
end
