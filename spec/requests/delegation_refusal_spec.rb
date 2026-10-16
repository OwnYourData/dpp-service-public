# frozen_string_literal: true

require "rails_helper"
require "digest"

# What the client is told when a delegation is refused at CreateDPP
# (docs/Delegation.md §15). The custodian does not say why it refused a grant:
# a delegation whose iss is not the controller of the collection, one that has
# expired and one that has been revoked all come back as invalid_grant, and the
# service answers each of them with ClientNotAuthorized (401). A delegation
# whose issuer does not resolve is refused the same way before the custodian is
# asked at all. Only insufficient_scope becomes ClientForbidden (403).
#
# The pod client is real; only the network is stubbed, so the requests that
# leave the service are visible. Every refusal happens before a DID is minted.
RSpec.describe "CreateDPP with a refused delegation", type: :request do
  let(:base_url)   { "https://dpp.go-data.at" }
  let(:product_id) { "https://id.lumina.example/01/09520123456788" }
  let(:owner)      { "did:oyd:zQmPPwHJK1NHBz3BS89StWsfrH4pzkyqwJiK94zVj25wXUS" }
  let(:bearer)     { "Bearer #{JWT.encode({ sub: owner, scope: 'dpp:write' }, nil, 'none')}" }

  let(:holder)      { Ed25519::SigningKey.new(Digest::SHA256.digest("delegation-refusal/holder")) }
  let(:service_key) { Ed25519::SigningKey.new(Digest::SHA256.digest("delegation-refusal/service")) }

  let(:document) do
    { "uniqueProductIdentifier" => product_id,
      "granularity" => "model",
      "dppSchemaVersion" => "EN 18223:2026",
      "economicOperatorId" => owner }
  end

  def delegation(issuer: owner)
    now = Time.now.to_i
    Delegation.sign(holder, typ: Delegation::TYP_DELEGATION, kid: "#{issuer}#key-doc",
                            payload: { "iss" => issuer, "sub" => "did:oyd:zService", "aud" => base_url,
                                       "collection" => "4", "product_id" => product_id,
                                       "act" => %w[create update delete], "purpose" => "dpp-hosting",
                                       "iat" => now, "nbf" => now, "exp" => now + (30 * 86_400),
                                       "jti" => "refusal-#{issuer[-6..]}" })
  end

  def create_with(mandate)
    storage = { base_url: base_url, collection_id: "4", delegation: mandate }.to_json
    post "/dpp/v1/dpps", params: document.to_json,
                         headers: { "Content-Type" => "application/json",
                                    "Authorization" => bearer,
                                    "X-DPP-Storage" => storage }
  end

  # The custodian's token endpoint answers with what is queued; nothing else
  # may be asked.
  def stub_custodian(token_endpoint: [])
    requests = []
    queue = Array(token_endpoint).dup

    allow(OutboundHttp).to receive(:perform) do |req, **|
      requests << req
      raise "unexpected request #{req.method} #{req.path}" unless req.path == "/oauth/token"

      status, body = queue.shift || raise("unexpected token request")
      OutboundHttp::Response.new(code: status.to_s, body: JSON.generate(body),
                                 message: "stubbed", version: "2.0")
    end
    requests
  end

  before do
    PodStorage.reset_token_cache!
    allow(ServiceDid).to receive(:did).and_return("did:oyd:zService")
    allow(ServiceDid).to receive(:signing_key).and_return(service_key)
    allow(DidTokenVerifier).to receive(:public_key_for) { |did| did == owner ? holder.verify_key : nil }
    allow(DidOyd).to receive(:mint)
  end

  # Delegation vector 06: the pod refuses a delegation whose iss is not the
  # controller_did of the collection with invalid_grant.
  it "answers ClientNotAuthorized when iss is not the controller of the collection" do
    requests = stub_custodian(token_endpoint: [[400, { "error" => "invalid_grant" }]])

    create_with(delegation)

    expect(response).to have_http_status(:unauthorized)
    expect(response.parsed_body["statusCode"]).to eq("ClientNotAuthorized")
    expect(requests.map(&:path)).to eq(["/oauth/token"])
    expect(DidOyd).not_to have_received(:mint)
    expect(Dpp.where(product_id: product_id)).to be_empty
  end

  it "answers ClientForbidden when act does not cover the operation" do
    stub_custodian(token_endpoint: [[400, { "error" => "insufficient_scope" }]])

    create_with(delegation)

    expect(response).to have_http_status(:forbidden)
    expect(response.parsed_body["statusCode"]).to eq("ClientForbidden")
    expect(DidOyd).not_to have_received(:mint)
  end

  it "answers ClientNotAuthorized when the issuer does not resolve, without asking the custodian" do
    requests = stub_custodian

    create_with(delegation(issuer: "did:oyd:zQmDoesNotResolve"))

    expect(response).to have_http_status(:unauthorized)
    expect(response.parsed_body["statusCode"]).to eq("ClientNotAuthorized")
    expect(requests).to be_empty
    expect(DidOyd).not_to have_received(:mint)
  end
end
