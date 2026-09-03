# frozen_string_literal: true

require "rails_helper"

# The mandate the service holds for a passport: reading it, and handing over a
# fresh one without moving the passport.
#
# The case this exists for is the ordinary one: a delegation runs 90 days
# (docs/Delegation.md §10) and a passport runs for years, so the mandate in
# store is *expired* by the time this endpoint is called. Every example here
# therefore also states what the endpoint must not do -- reach for the stored
# mandate as if it were still an authority.
#
# The pod is stubbed; what is under test is the wiring inside this service.
RSpec.describe "Renewing the delegation", type: :request do
  let(:owner) { "did:oyd:zQmPPwHJK1NHBz3BS89StWsfrH4pzkyqwJiK94zVj25wXUS" }
  let(:token) { "Bearer #{JWT.encode({ iss: owner, sub: owner, scope: 'dpp:write' }, nil, 'none')}" }

  let(:base_url)      { "https://dpp.go-data.at" }
  let(:collection_id) { "4" }
  let(:product_id)    { "https://dpp.oydapp.eu/01/09520123456791/21/000123" }
  let(:minted) do
    { did: "did:oyd:zPODhash123456", doc_key: "doc-secret", rev_key: "rev-secret", rev_log: "rev-log" }
  end
  let(:dpp_id) { minted[:did] }

  let(:now) { Time.now.to_i }

  # A delegation as it is stored and read back: not signed, but decodable, which
  # is all Delegation.peek asks of it.
  def delegation_token(claims)
    part = ->(obj) { Base64.urlsafe_encode64(JSON.generate(obj), padding: false) }
    header = { "alg" => "EdDSA", "typ" => "dpp-delegation+jwt" }
    "#{part.call(header)}.#{part.call(claims)}.c2ln"
  end

  def claims(exp:, act: %w[create update delete], product: product_id, jti: SecureRandom.hex(4))
    { "iss" => owner, "sub" => "did:oyd:zService", "aud" => base_url,
      "collection" => collection_id, "product_id" => product, "act" => act,
      "purpose" => "dpp-custody", "iat" => now, "nbf" => now,
      "exp" => exp, "jti" => jti }
  end

  # A stubbed custodian. ensure_product! mirrors the real comparison, because
  # the mismatch is one of the refusals under test here; the real method is
  # covered in spec/services/pod_storage_spec.rb.
  def custodian(claim_set, object_id: "obj-a")
    delegation = delegation_token(claim_set)
    fake = instance_double(PodStorage,
                           base_url: base_url,
                           collection_id: collection_id,
                           storage_delegation: delegation,
                           delegation_claims: claim_set,
                           reachable!: true)
    store = {}
    allow(fake).to receive(:ensure_covers!).and_return(true)
    allow(fake).to receive(:ensure_product!) do |pid|
      unless claim_set["product_id"] == pid
        raise PodStorage::DelegationError.new(
          "the delegation is for product #{claim_set['product_id'].inspect}, not #{pid.inspect}",
          status_code: "ClientForbidden"
        )
      end
      true
    end
    allow(fake).to receive(:create_object).and_return(object_id)
    allow(fake).to receive(:write_payload) { |_id, doc| store[:doc] = doc; true }
    allow(fake).to receive(:read_payload) { store[:doc] || {} }
    allow(fake).to receive(:delete_object).and_return(true)
    fake
  end

  # In place at creation time: still valid, and it covers everything.
  let(:stored_claims) { claims(exp: now + (30 * 86_400)) }
  let(:stored) { custodian(stored_claims) }

  # What the holder signs when the old one is running out.
  let(:fresh_claims) { claims(exp: now + (90 * 86_400)) }
  let(:fresh) { custodian(fresh_claims) }

  def storage_header(pod, url: base_url, collection: collection_id)
    { base_url: url, collection_id: collection,
      delegation: pod.storage_delegation }.to_json
  end

  let(:document) do
    { "uniqueProductIdentifier" => product_id,
      "granularity" => "item",
      "dppSchemaVersion" => "EN 18223:2026",
      "economicOperatorId" => owner }
  end

  def create_headers
    { "Content-Type" => "application/json", "Authorization" => token,
      "X-DPP-Storage" => storage_header(stored) }
  end

  def renew(pod, headers: nil)
    post "/dpp/v1/dpps/#{CGI.escape(dpp_id)}/delegation",
         headers: headers || { "Authorization" => token, "X-DPP-Storage" => storage_header(pod) }
  end

  before do
    allow(DidOyd).to receive(:mint).and_return(minted)
    allow(PodStorage).to receive(:from_header).and_return(stored)
    allow(PodStorage).to receive(:for).and_return(stored)

    post "/dpp/v1/dpps", params: document.to_json, headers: create_headers
    expect(response).to have_http_status(:created)

    # From here on the stored mandate is off limits: the endpoint has to work
    # with an expired one, so anything that reaches for it is a bug.
    allow(PodStorage).to receive(:for)
      .and_raise("renewing a delegation must not use the stored one")
    allow(PodStorage).to receive(:from_header).and_return(fresh)
  end

  describe "the ordinary case" do
    it "replaces the stored mandate and answers 204" do
      renew(fresh)

      expect(response).to have_http_status(:no_content)
      expect(response.body).to be_empty
      expect(Dpp.find(dpp_id).storage_delegation).to eq(fresh.storage_delegation)
    end

    it "proves the fresh mandate at the pod before overwriting anything" do
      renew(fresh)

      expect(fresh).to have_received(:reachable!)
    end

    it "leaves custodian, collection and the document where they are" do
      before_renewal = Dpp.find(dpp_id)

      renew(fresh)

      after = Dpp.find(dpp_id)
      expect(after.storage_base_url).to eq(before_renewal.storage_base_url)
      expect(after.storage_collection_id).to eq(before_renewal.storage_collection_id)
      expect(after.storage_object_id).to eq(before_renewal.storage_object_id)
      expect(fresh).not_to have_received(:create_object)
      expect(fresh).not_to have_received(:write_payload)
    end
  end

  # The reason the endpoint exists.
  describe "when the stored mandate has expired" do
    let(:stored_claims) { claims(exp: now - (5 * 86_400)) }

    it "still accepts a fresh one" do
      renew(fresh)

      expect(response).to have_http_status(:no_content)
      expect(Dpp.find(dpp_id).storage_delegation).to eq(fresh.storage_delegation)
    end
  end

  # Nothing to compare against, so the two comparison rules fall away -- but the
  # renewal itself must still go through.
  describe "when the stored mandate is no longer readable" do
    before do
      Dpp.find(dpp_id).update_column(:storage_delegation, "not-a-jwt")
    end

    it "accepts a fresh one" do
      renew(fresh)

      expect(response).to have_http_status(:no_content)
      expect(Dpp.find(dpp_id).storage_delegation).to eq(fresh.storage_delegation)
    end
  end

  # Reading back what the service holds. The holder's own record and the
  # service's state drift apart after a restore from an older backup, and
  # nothing else makes that visible.
  describe "reading the mandate in place" do
    def read_delegation(auth: token)
      get "/dpp/v1/dpps/#{CGI.escape(dpp_id)}/delegation",
          headers: auth ? { "Authorization" => auth } : {}
    end

    it "reports the five claims of the stored mandate" do
      read_delegation

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body).to eq(
        "jti" => stored_claims["jti"],
        "exp" => stored_claims["exp"],
        "act" => %w[create update delete],
        "collection" => collection_id,
        "base_url" => base_url
      )
    end

    it "follows a renewal" do
      renew(fresh)
      expect(response).to have_http_status(:no_content)

      read_delegation

      expect(response.parsed_body["jti"]).to eq(fresh_claims["jti"])
      expect(response.parsed_body["exp"]).to eq(fresh_claims["exp"])
    end

    # An expired mandate is exactly what the caller is here to find out about,
    # so nothing about the claims is checked.
    context "when the stored mandate has expired" do
      let(:stored_claims) { claims(exp: now - (5 * 86_400)) }

      it "reports it rather than refusing" do
        read_delegation

        expect(response).to have_http_status(:ok)
        expect(response.parsed_body["exp"]).to eq(stored_claims["exp"])
      end
    end

    it "reports nothing at all when the stored mandate cannot be read" do
      Dpp.find(dpp_id).update_column(:storage_delegation, "not-a-jwt")

      read_delegation

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body.values).to all(be_nil)
    end

    it "does not read the passport out of the pod" do
      read_delegation

      expect(stored).not_to have_received(:read_payload)
      expect(response.parsed_body).not_to have_key("uniqueProductIdentifier")
    end

    it "answers 404 for a passport no custodian holds" do
      Dpp.find(dpp_id).update_columns(storage_backend: "local", content: {})

      read_delegation

      expect(response).to have_http_status(:not_found)
    end

    it "refuses without a bearer token" do
      read_delegation(auth: nil)

      expect(response).to have_http_status(:unauthorized)
    end

    context "with DID authentication enabled" do
      let(:stranger) { "did:oyd:zStrangerBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB" }

      before do
        allow(DidTokenVerifier).to receive(:enabled?).and_return(true)
        allow(DidTokenVerifier).to receive(:call) do |raw|
          decoded = begin
            JWT.decode(raw.to_s, nil, false).first
          rescue JWT::DecodeError
            nil
          end
          decoded if decoded && decoded["iss"].to_s.start_with?("did:")
        end
        Dpp.find(dpp_id).update_column(:owner_did, owner)
      end

      it "tells no one but the owner" do
        read_delegation(auth: "Bearer #{JWT.encode({ iss: stranger, sub: stranger }, nil, 'none')}")

        expect(response).to have_http_status(:forbidden)
      end

      it "tells the owner" do
        read_delegation

        expect(response).to have_http_status(:ok)
        expect(response.parsed_body["jti"]).to eq(stored_claims["jti"])
      end
    end
  end

  describe "refusals" do
    def expect_unchanged
      expect(Dpp.find(dpp_id).storage_delegation).to eq(stored.storage_delegation)
    end

    it "refuses without a mandate" do
      renew(fresh, headers: { "Authorization" => token })

      expect(response).to have_http_status(:bad_request)
      expect_unchanged
    end

    it "refuses a mandate for another custodian and points at custody" do
      other = base_url
      elsewhere = custodian(claims(exp: now + (90 * 86_400)).merge("aud" => "https://dpp.data-vault.eu"))
      allow(elsewhere).to receive(:base_url).and_return("https://dpp.data-vault.eu")
      allow(PodStorage).to receive(:from_header).and_return(elsewhere)

      renew(elsewhere)

      expect(response).to have_http_status(:bad_request)
      expect(response.parsed_body["message"].first["text"]).to include("custody")
      expect(Dpp.find(dpp_id).storage_base_url).to eq(other)
      expect_unchanged
    end

    it "refuses a mandate for another collection" do
      other = custodian(claims(exp: now + (90 * 86_400)).merge("collection" => "9"))
      allow(other).to receive(:collection_id).and_return("9")
      allow(PodStorage).to receive(:from_header).and_return(other)

      renew(other)

      expect(response).to have_http_status(:bad_request)
      expect_unchanged
    end

    it "refuses a mandate for another product" do
      other = custodian(claims(exp: now + (90 * 86_400),
                               product: "https://dpp.oydapp.eu/01/09520123456791/21/000999"))
      allow(PodStorage).to receive(:from_header).and_return(other)

      renew(other)

      expect(response).to have_http_status(:forbidden)
      expect_unchanged
    end

    it "refuses a mandate that grants less than the stored one" do
      narrower = custodian(claims(exp: now + (90 * 86_400), act: %w[update]))
      allow(PodStorage).to receive(:from_header).and_return(narrower)

      renew(narrower)

      expect(response).to have_http_status(:forbidden)
      expect(response.parsed_body["message"].first["text"]).to include("create")
      expect(narrower).not_to have_received(:reachable!)
      expect_unchanged
    end

    it "refuses a mandate that expires no later than the stored one" do
      shorter = custodian(claims(exp: now + (10 * 86_400)))
      allow(PodStorage).to receive(:from_header).and_return(shorter)

      renew(shorter)

      expect(response).to have_http_status(:bad_request)
      expect(shorter).not_to have_received(:reachable!)
      expect_unchanged
    end

    it "refuses when the pod does not honour the fresh mandate" do
      allow(fresh).to receive(:reachable!)
        .and_raise(PodStorage::Error.new("pod unreachable"))

      renew(fresh)

      expect(response).to have_http_status(:bad_gateway)
      expect_unchanged
    end

    it "refuses for a passport that is not held by a custodian" do
      Dpp.find(dpp_id).update_columns(storage_backend: "local", content: {})

      renew(fresh)

      expect(response).to have_http_status(:bad_request)
    end

    it "refuses without a bearer token" do
      post "/dpp/v1/dpps/#{CGI.escape(dpp_id)}/delegation",
           headers: { "X-DPP-Storage" => storage_header(fresh) }

      expect(response).to have_http_status(:unauthorized)
      expect_unchanged
    end
  end

  # In permissive mode there is no verified identity, so ownership cannot mean
  # anything; with DID authentication on it does.
  describe "with DID authentication enabled" do
    let(:stranger) { "did:oyd:zStrangerBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB" }

    before do
      allow(DidTokenVerifier).to receive(:enabled?).and_return(true)
      allow(DidTokenVerifier).to receive(:call) do |raw|
        claims = begin
          JWT.decode(raw.to_s, nil, false).first
        rescue JWT::DecodeError
          nil
        end
        claims if claims && claims["iss"].to_s.start_with?("did:")
      end
      Dpp.find(dpp_id).update_column(:owner_did, owner)
    end

    it "refuses a renewal from anyone but the owner" do
      stranger_token = "Bearer #{JWT.encode({ iss: stranger, sub: stranger }, nil, 'none')}"

      post "/dpp/v1/dpps/#{CGI.escape(dpp_id)}/delegation",
           headers: { "Authorization" => stranger_token,
                      "X-DPP-Storage" => storage_header(fresh) }

      expect(response).to have_http_status(:forbidden)
      expect(fresh).not_to have_received(:reachable!)
      expect(Dpp.find(dpp_id).storage_delegation).to eq(stored.storage_delegation)
    end

    it "accepts it from the owner" do
      renew(fresh)

      expect(response).to have_http_status(:no_content)
    end
  end
end
