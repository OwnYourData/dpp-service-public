# frozen_string_literal: true

require "rails_helper"
require "digest"

# A delegation runs 90 days (docs/Delegation.md §10), a passport runs for years.
# Reading its public part therefore must not depend on the mandate: the
# service reads it over the custodian's public path, without a token, and keeps
# answering after the mandate has run out or the custodian has stopped taking
# writes for it. Writing still needs the mandate and fails without it, leaving
# nothing behind.
#
# Unlike spec/requests/pod_storage_spec.rb, the pod client is real here; only
# the network is stubbed, so the requests that leave the service are visible.
RSpec.describe "Reading a pod-held passport without a mandate", type: :request do
  let(:base_url)   { "https://dpp-staging.go-data.at" }
  let(:dpp_id)     { "did:oyd:zQmExpiredMandate" }
  let(:product_id) { "https://dpp.oydapp.eu/01/09520123456788/21/000001" }
  let(:owner)      { "did:oyd:zQmPPwHJK1NHBz3BS89StWsfrH4pzkyqwJiK94zVj25wXUS" }
  let(:bearer)     { "Bearer #{JWT.encode({ sub: owner, scope: 'dpp:write' }, nil, 'none')}" }

  let(:holder)      { Ed25519::SigningKey.new(Digest::SHA256.digest("reading-without-mandate/holder")) }
  let(:service_key) { Ed25519::SigningKey.new(Digest::SHA256.digest("reading-without-mandate/service")) }

  # What the custodian serves for this passport.
  let(:stored) do
    { "digitalProductPassportId" => dpp_id,
      "uniqueProductIdentifier" => product_id,
      "granularity" => "item",
      "dppSchemaVersion" => "EN 18223:2026",
      "dppStatus" => "Active",
      "economicOperatorId" => owner,
      "elements" => [{ "elementId" => "EnergyPerformance",
                       "elements" => [{ "elementId" => "LuminousFlux", "value" => 806 }] }] }
  end

  def delegation(exp:)
    now = Time.now.to_i
    Delegation.sign(holder, typ: Delegation::TYP_DELEGATION, kid: "#{owner}#key-doc",
                            payload: { "iss" => owner, "sub" => "did:oyd:zService", "aud" => base_url,
                                       "collection" => "4", "product_id" => product_id,
                                       "act" => %w[create update delete], "purpose" => "dpp-hosting",
                                       "iat" => [exp, now].min - 3600, "nbf" => [exp, now].min - 3600,
                                       "exp" => exp, "jti" => "jti-#{exp}" })
  end

  let(:expired_mandate) { delegation(exp: Time.now.to_i - 86_400) }
  let(:valid_mandate)   { delegation(exp: Time.now.to_i + (30 * 86_400)) }

  def passport_with(mandate)
    Dpp.create!(dpp_id: dpp_id, product_id: product_id, granularity: "item",
                dpp_schema_version: "EN 18223:2026", dpp_status: "Active",
                economic_operator_id: owner, owner_did: owner, last_update: Time.now.utc,
                facility_id: "F-1",
                storage_backend: "pod", storage_base_url: base_url, storage_collection_id: "4",
                storage_delegation: mandate, storage_object_id: "4711", content: {})
  end

  # The custodian. Public paths answer with the stored document; what the
  # resource and token endpoint say is set per example.
  def stub_custodian(token_endpoint: [], resource: [])
    requests = []
    token_queue    = Array(token_endpoint).dup
    resource_queue = Array(resource).dup

    allow(OutboundHttp).to receive(:perform) do |req, **|
      requests << req
      status, body =
        if req.path.start_with?("/dpp/v1/")
          [200, stored]
        elsif req.path == "/oauth/token"
          token_queue.shift || raise("unexpected token request")
        else
          resource_queue.shift || raise("unexpected resource request #{req.method} #{req.path}")
        end
      OutboundHttp::Response.new(code: status.to_s, body: JSON.generate(body),
                                 message: "stubbed", version: "2.0")
    end
    requests
  end

  def token(access) = [200, { "access_token" => access, "token_type" => "DPoP", "expires_in" => 600 }]
  let(:invalid_grant) { [400, { "error" => "invalid_grant" }] }
  let(:invalid_token) { [401, { "error" => "invalid_token" }] }
  let(:written)       { [200, {}] }

  def patch_facility(value)
    patch "/dpp/v1/dpps/#{CGI.escape(dpp_id)}",
          params: { "facilityId" => value }.to_json,
          headers: { "Content-Type" => "application/merge-patch+json", "Authorization" => bearer }
  end

  before do
    PodStorage.reset_token_cache!
    allow(ServiceDid).to receive(:did).and_return("did:oyd:zService")
    allow(ServiceDid).to receive(:signing_key).and_return(service_key)
  end

  describe "with a mandate that has expired" do
    before { passport_with(expired_mandate) }

    it "still answers ReadDPPById with 200" do
      requests = stub_custodian

      get "/dpp/v1/dpps/#{CGI.escape(dpp_id)}?representation=full"

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body["elements"].first["elementId"]).to eq("EnergyPerformance")
      expect(requests.map(&:path)).to eq(["/dpp/v1/dpps/#{ERB::Util.url_encode(dpp_id)}?representation=full"])
      expect(requests.map { |r| r["Authorization"] }).to all(be_nil)
    end

    it "still answers ReadDPPByProductId with 200" do
      requests = stub_custodian

      get "/dpp/v1/dppsByProductId/#{CGI.escape(product_id)}"

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body["digitalProductPassportId"]).to eq(dpp_id)
      expect(requests.map(&:path)).not_to include("/oauth/token")
    end

    it "still answers in the default representation" do
      stub_custodian

      get "/dpp/v1/dpps/#{CGI.escape(dpp_id)}"

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body["digitalProductPassportId"]).to eq(dpp_id)
    end

    it "still reads a single data element" do
      stub_custodian

      get "/dpp/v1/dpps/#{CGI.escape(dpp_id)}/elements/EnergyPerformance/LuminousFlux"

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body).to eq(806)
    end

    it "refuses UpdateDPP with ClientNotAuthorized and changes nothing" do
      requests = stub_custodian

      patch_facility("F-2")

      expect(response).to have_http_status(:unauthorized)
      expect(response.parsed_body["statusCode"]).to eq("ClientNotAuthorized")
      expect(Dpp.find(dpp_id).facility_id).to eq("F-1")
      expect(requests).to be_empty
    end

    it "refuses DeleteDPPById with ClientNotAuthorized before revoking anything" do
      stub_custodian
      allow(DidOyd).to receive(:revoke)

      delete "/dpp/v1/dpps/#{CGI.escape(dpp_id)}", headers: { "Authorization" => bearer }

      expect(response).to have_http_status(:unauthorized)
      expect(DidOyd).not_to have_received(:revoke)
      expect(Dpp.find(dpp_id).dpp_status).to eq("Active")
    end
  end

  # The custodian stops taking writes (invalid_grant at the token endpoint)
  # while the mandate is still within its lifetime.
  describe "with a mandate the custodian refuses" do
    before { passport_with(valid_mandate) }

    it "still answers ReadDPPById with 200" do
      stub_custodian

      get "/dpp/v1/dpps/#{CGI.escape(dpp_id)}"

      expect(response).to have_http_status(:ok)
    end

    it "refuses UpdateDPP with ClientNotAuthorized and keeps the local row as it was" do
      requests = stub_custodian(token_endpoint: [invalid_grant])

      patch_facility("F-2")

      expect(response).to have_http_status(:unauthorized)
      expect(Dpp.find(dpp_id).facility_id).to eq("F-1")
      expect(requests.count { |r| r.path == "/oauth/token" }).to eq(1)
    end
  end

  describe "a token refused at the resource" do
    before { passport_with(valid_mandate) }

    it "is replaced once, and the update goes through" do
      requests = stub_custodian(token_endpoint: [token("first"), token("second")],
                                resource: [invalid_token, written])

      patch_facility("F-2")

      expect(response).to have_http_status(:ok)
      expect(Dpp.find(dpp_id).facility_id).to eq("F-2")
      expect(requests.count { |r| r.path == "/oauth/token" }).to eq(2)
    end

    it "ends the update with ClientNotAuthorized when the new token is refused too" do
      requests = stub_custodian(token_endpoint: [token("first"), token("second")],
                                resource: [invalid_token, invalid_token])

      patch_facility("F-2")

      expect(response).to have_http_status(:unauthorized)
      expect(Dpp.find(dpp_id).facility_id).to eq("F-1")
      expect(requests.count { |r| r.path == "/oauth/token" }).to eq(2)
    end

    it "is replaced once per incoming request, not once per process" do
      stub_custodian(token_endpoint: [token("first"), token("second"), token("third")],
                     resource: [invalid_token, written, invalid_token, written])

      patch_facility("F-2")
      expect(response).to have_http_status(:ok)

      patch_facility("F-3")
      expect(response).to have_http_status(:ok)
      expect(Dpp.find(dpp_id).facility_id).to eq("F-3")
    end
  end
end
