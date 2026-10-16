# frozen_string_literal: true

require "digest"
require "ed25519"
require_relative "fake_pod"

# A passport mirroring the one on dpp-staging (BrandName public, SerialNumber
# legitimateInterest, OnModePower authority), its owner, two readers with
# access grants, one without, and a custodian that holds controlled cards.
# Shared by the specs of reading per role and of the access log.
RSpec.shared_context "reading with access rights" do
  let(:held) { "https://dpp-staging.go-data.at" }
  let(:pod)  { FakePod.new(held) }

  let(:owner)       { "did:oyd:zQmTestOperator" }
  let(:li_reader)   { "did:oyd:zQmRepairShop" }
  let(:au_reader)   { "did:oyd:zQmMarketSurveillance" }
  let(:nobody)      { "did:oyd:zQmNobody" }
  let(:au_issuer)   { "did:oyd:zQmTestAuthorityIssuer" }

  let(:owner_key)   { Ed25519::SigningKey.new(Digest::SHA256.digest("reading/owner")) }
  let(:issuer_key)  { Ed25519::SigningKey.new(Digest::SHA256.digest("reading/issuer")) }
  let(:service_key) { Ed25519::SigningKey.new(Digest::SHA256.digest("reading/service")) }
  let(:reader_key)  { Ed25519::SigningKey.new(Digest::SHA256.digest("reading/reader")) }
  let(:reader)      { instance_double(ReaderDid, did: "did:oyd:zQmServiceReader", pod: held, signing_key: reader_key) }

  let(:product_id) { "https://dpp.oydapp.eu/01/09520123456788/21/000921" }
  let(:dpp_id)     { "did:oyd:zQmReadingWithAccess921" }
  let(:enc)        { CGI.escape(dpp_id) }

  let(:policy_doc) do
    { "id" => "https://dpp.example.org/access-policies/cap-020/1",
      "scheme" => AccessClass::SCHEME,
      "default" => "public",
      "rules" => [
        { "path" => "SerialNumber", "accessClass" => "legitimateInterest" },
        { "path" => "OnModePower", "accessClass" => "authority" }
      ] }
  end

  def single(id, value) = { "elementId" => id, "objectType" => "SingleValuedDataElement", "value" => value }

  def document(serial: "SN-0921", power: 7.5, brand: "Lumina")
    { "digitalProductPassportId" => dpp_id,
      "uniqueProductIdentifier" => product_id,
      "granularity" => "item",
      "dppSchemaVersion" => "EN 18223:2026",
      "dppStatus" => "Active",
      "economicOperatorId" => owner,
      "elements" => [single("BrandName", brand), single("SerialNumber", serial), single("OnModePower", power)] }
  end

  def bearer(did) = "Bearer #{JWT.encode({ 'iss' => did, 'sub' => did }, nil, 'none')}"

  def json_headers(did, extra = {})
    { "Content-Type" => "application/json", "Authorization" => bearer(did) }.merge(extra)
  end

  def mandate
    now = Time.now.to_i
    Delegation.sign(owner_key, typ: Delegation::TYP_DELEGATION, kid: "#{owner}#key-doc",
                               payload: { "iss" => owner, "sub" => "did:oyd:zService", "aud" => held,
                                          "collection" => "60", "product_id" => product_id,
                                          "act" => %w[create update delete], "purpose" => "dpp-hosting",
                                          "iat" => now, "nbf" => now, "exp" => now + 86_400, "jti" => "m1" })
  end

  def storage_header = { base_url: held, collection_id: "60", delegation: mandate }.to_json

  def register_policy
    put "/dpp/v1/access-policies", params: policy_doc.to_json, headers: json_headers(owner)
    expect(response.status).to be_in([200, 201])
  end

  def create_at_pod(with_policy: true)
    register_policy
    extra = { "X-DPP-Storage" => storage_header }
    extra["X-DPP-Access-Policy"] = policy_doc["id"] if with_policy
    post "/dpp/v1/dpps", params: document.to_json, headers: json_headers(owner, extra)
    expect(response).to have_http_status(:created)
  end

  def create_locally
    register_policy
    post "/dpp/v1/dpps", params: document.merge("digitalProductPassportId" => dpp_id).to_json,
                         headers: json_headers(owner, "X-DPP-Access-Policy" => policy_doc["id"])
    expect(response).to have_http_status(:created)
  end

  def update_passport(extra = {}, **values)
    patch "/dpp/v1/dpps/#{enc}", params: { "elements" => document(**values)["elements"] }.to_json,
                                 headers: json_headers(owner, { "Content-Type" => "application/merge-patch+json" }.merge(extra))
    expect(response).to have_http_status(:ok)
  end

  def grant(issuer:, key:, sub:, roles:, dpps: [dpp_id], scope: nil, jti: SecureRandom.hex(4),
            exp: Time.now.to_i + 86_400)
    now = Time.now.to_i
    claims = { "iss" => issuer, "sub" => sub, "aud" => "did:oyd:zService", "roles" => roles,
               "iat" => now, "nbf" => now, "exp" => exp, "jti" => jti }
    scope ? claims["scope"] = scope : claims["dpps"] = dpps
    Delegation.sign(key, typ: Delegation::TYP_GRANT, kid: "#{issuer}#key-doc", payload: claims)
  end

  def register_grant(token, as:)
    put "/dpp/v1/access-grants", params: token, headers: { "Content-Type" => "application/jwt",
                                                           "Authorization" => bearer(as) }
  end

  def grant_roles!
    register_grant(grant(issuer: owner, key: owner_key, sub: li_reader, roles: ["legitimateInterest"]), as: owner)
    expect(response).to have_http_status(:created)
    register_grant(grant(issuer: au_issuer, key: issuer_key, sub: au_reader, roles: ["authority"]), as: au_issuer)
    expect(response).to have_http_status(:created)
  end

  def read(path, as: nil)
    get path, headers: as ? { "Authorization" => bearer(as) } : {}
  end

  def element_ids(body) = PassportSplit.attribute_paths(body)
  def value_of(body, id) = Array(body["elements"]).find { |e| e["elementId"] == id }&.fetch("value", nil)

  def passport_paths
    ["/dpp/v1/dpps/#{enc}?representation=full",
     "/dpp/v1/dppsByProductId/#{CGI.escape(product_id)}?representation=full"]
  end

  def who(key) = { nil => nil, "nobody" => nobody, "li" => li_reader, "au" => au_reader, "owner" => owner }[key]

  before do
    PodStorage.reset_token_cache!
    pod.readers << reader.did
    allow(ReaderDid).to receive(:for_pod).with(held).and_return(reader)
    allow(ServiceDid).to receive(:did).and_return("did:oyd:zService")
    allow(ServiceDid).to receive(:signing_key).and_return(service_key)
    allow(PodStorage).to receive(:from_header) { |raw, **| PodStorage.from_hash(JSON.parse(raw), verify: false) }
    allow(DidOyd).to receive(:assert_endpoint_host!).and_return(true)
    allow(DidOyd).to receive(:revoke)
    allow(ENV).to receive(:[]).and_call_original
    allow(ENV).to receive(:[]).with("DPP_CONTROLLED_CARD_PODS").and_return(held)
    allow(ENV).to receive(:[]).with("DPP_AUTHORITY_ISSUERS").and_return(au_issuer)
    allow(DidTokenVerifier).to receive(:enabled?).and_return(true)
    allow(DidTokenVerifier).to receive(:call) do |token|
      claims = begin
        JWT.decode(token.to_s, nil, false).first
      rescue JWT::DecodeError
        nil
      end
      claims if claims && claims["iss"].to_s.start_with?("did:")
    end
    allow(DidTokenVerifier).to receive(:public_key_for) do |did|
      { owner => owner_key, au_issuer => issuer_key }[did]&.verify_key
    end
    allow(OutboundHttp).to receive(:perform) do |req, **|
      raise "no custodian for #{req.url}" unless pod.handles?(req)

      status, body = pod.call(req)
      OutboundHttp::Response.new(code: status.to_s, body: body.is_a?(String) ? body : JSON.generate(body),
                                 message: "stubbed", version: "2.0")
    end
  end
end
