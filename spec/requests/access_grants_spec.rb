# frozen_string_literal: true

require "rails_helper"
require "digest"
require "ed25519"

# Registering access grants (docs/AccessClasses.md §7, AccessGrant): an economic
# operator grants legitimateInterest for its own passports, only an issuer on
# the list of authority issuers grants authority, and a grant is registered
# by its issuer, once.
RSpec.describe "Access grants", type: :request do
  let(:operator)  { "did:oyd:zQmOperator" }
  let(:other_op)  { "did:oyd:zQmOtherOperator" }
  let(:issuer)    { "did:oyd:zQmAuthorityIssuer" }
  let(:reader)    { "did:oyd:zQmReader" }

  let(:keys) do
    [operator, other_op, issuer].to_h { |did| [did, Ed25519::SigningKey.new(Digest::SHA256.digest("grants/#{did}"))] }
  end

  let(:own_dpp)   { "https://dpp.lumina.example/x/own" }
  let(:other_dpp) { "https://dpp.lumina.example/x/other" }

  def bearer(did) = "Bearer #{JWT.encode({ 'iss' => did, 'sub' => did }, nil, 'none')}"

  def grant(issuer_did, roles: ["legitimateInterest"], dpps: [own_dpp], scope: nil, jti: "g-1", sub: reader)
    now = Time.now.to_i
    claims = { "iss" => issuer_did, "sub" => sub, "aud" => "did:oyd:zService", "roles" => roles,
               "iat" => now, "nbf" => now, "exp" => now + 86_400, "jti" => jti }
    scope ? claims["scope"] = scope : claims["dpps"] = dpps
    Delegation.sign(keys.fetch(issuer_did), typ: Delegation::TYP_GRANT, kid: "#{issuer_did}#key-doc", payload: claims)
  end

  def register(token, as:)
    put "/dpp/v1/access-grants", params: token,
                                 headers: { "Content-Type" => "application/jwt", "Authorization" => bearer(as) }
  end

  def passport(dpp_id, owner, product_id)
    Dpp.create!(dpp_id: dpp_id, product_id: product_id,
                granularity: "model", dpp_schema_version: "EN 18223:2026", economic_operator_id: owner,
                last_update: Time.now.utc, owner_did: owner, content: {})
  end

  before do
    passport(own_dpp, operator, "https://id.lumina.example/01/09520123456788")
    passport(other_dpp, other_op, "https://id.lumina.example/01/09520123456795")
    allow(ServiceDid).to receive(:did).and_return("did:oyd:zService")
    allow(ENV).to receive(:[]).and_call_original
    allow(ENV).to receive(:[]).with("DPP_AUTHORITY_ISSUERS").and_return(issuer)
    allow(DidTokenVerifier).to receive(:enabled?).and_return(true)
    allow(DidTokenVerifier).to receive(:call) do |token|
      claims = JWT.decode(token.to_s, nil, false).first
      claims if claims["iss"].to_s.start_with?("did:")
    rescue JWT::DecodeError
      nil
    end
    allow(DidTokenVerifier).to receive(:public_key_for) { |did| keys[did]&.verify_key }
  end

  it "registers a grant of an operator for its own passport with 201" do
    register(grant(operator), as: operator)

    expect(response).to have_http_status(:created)
    expect(response.parsed_body).to include("sub" => reader, "roles" => ["legitimateInterest"],
                                            "dpps" => [own_dpp], "revoked" => false)
    expect(AccessGrant.sole.issuer_did).to eq(operator)
  end

  it "answers the same grant again with 200 and keeps one" do
    token = grant(operator)
    register(token, as: operator)
    register(token, as: operator)

    expect(response).to have_http_status(:ok)
    expect(AccessGrant.count).to eq(1)
  end

  it "refuses a different grant under the same jti with 409" do
    register(grant(operator), as: operator)
    register(grant(operator, sub: "did:oyd:zQmSomeoneElse"), as: operator)

    expect(response).to have_http_status(:conflict)
  end

  it "refuses a grant for a passport of another operator with 403" do
    register(grant(operator, dpps: [own_dpp, other_dpp]), as: operator)

    expect(response).to have_http_status(:forbidden)
    expect(AccessGrant.count).to eq(0)
  end

  it "refuses authority from an operator with 403" do
    register(grant(operator, roles: ["authority"]), as: operator)

    expect(response).to have_http_status(:forbidden)
    expect(response.parsed_body["message"].first["text"]).to match(/list of issuers/)
  end

  it "takes authority from an issuer on the list, for every passport" do
    register(grant(issuer, roles: ["authority"], scope: "issuer"), as: issuer)

    expect(response).to have_http_status(:created)
    expect(AccessGrant.roles_for(reader, dpp_id: other_dpp, owner_did: other_op)).to eq(["authority"])
  end

  it "covers with scope issuer only the passports of the operator that granted it" do
    register(grant(operator, scope: "issuer"), as: operator)

    expect(AccessGrant.roles_for(reader, dpp_id: own_dpp, owner_did: operator)).to eq(["legitimateInterest"])
    expect(AccessGrant.roles_for(reader, dpp_id: other_dpp, owner_did: other_op)).to be_empty
  end

  it "is registered by its issuer only" do
    register(grant(operator), as: other_op)

    expect(response).to have_http_status(:forbidden)
  end

  it "refuses a grant that does not hold with 400" do
    register("not.a.grant", as: operator)
    expect(response).to have_http_status(:bad_request)

    register("", as: operator)
    expect(response).to have_http_status(:bad_request)
  end

  it "needs a token" do
    put "/dpp/v1/access-grants", params: grant(operator), headers: { "Content-Type" => "application/jwt" }

    expect(response).to have_http_status(:unauthorized)
  end

  it "lists an issuer its own grants, without the signed statement" do
    register(grant(operator), as: operator)
    register(grant(issuer, roles: ["authority"], scope: "issuer", jti: "g-2"), as: issuer)

    get "/dpp/v1/access-grants", headers: { "Authorization" => bearer(operator) }

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body.map { |g| g["jti"] }).to eq(["g-1"])
    expect(response.body).not_to include(grant(operator).split(".").last)
  end
end
