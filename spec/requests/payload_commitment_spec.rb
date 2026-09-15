# frozen_string_literal: true

require "rails_helper"

# The wiring, not the commitment itself: that every path which changes a payload
# asks for a new commitment afterwards, and that every read says which state the
# passport is in. What the commitment does is spec/services/payload_commitment_spec.rb.
#
# PayloadCommitment.call is stubbed for request specs in rails_helper -- it reads
# the payload back from the custodian and writes to the VDR, neither of which
# belongs in a request.
RSpec.describe "Payload commitment", type: :request do
  let(:token) { "Bearer #{JWT.encode({ sub: 'did:oyd:zQmPPwHJK1NHBz3BS89StWsfrH4pzkyqwJiK94zVj25wXUS' }, nil, 'none')}" }
  let(:json)  { { "Content-Type" => "application/json" } }
  let(:auth)  { json.merge("Authorization" => token) }
  let(:patch_headers) { auth.merge("Content-Type" => "application/merge-patch+json") }

  # A client-minted identifier (Variante B): a did:oyd, so there is a log a
  # commitment could go into, and no minting to stub out.
  let(:dpp_id)     { "did:oyd:zQmTMPiMZ6mUg5bVXQxkuZ1JCgmtKE9QNu514EdMUydq9zL" }
  let(:product_id) { "https://dpp.oydapp.eu/01/09520123456788/21/000001" }
  let(:enc_dpp)    { CGI.escape(dpp_id) }
  let(:enc_prod)   { CGI.escape(product_id) }

  let(:dpp_document) do
    {
      "digitalProductPassportId" => dpp_id,
      "uniqueProductIdentifier"  => product_id,
      "granularity"              => "item",
      "dppSchemaVersion"         => "EN 18223:2026",
      "dppStatus"                => "Active",
      "economicOperatorId"       => "did:web:lumina.example",
      "elements" => [
        { "elementId" => "EnergyPerformance", "objectType" => "DataElementCollection",
          "elements" => [
            { "objectType" => "SingleValuedDataElement", "elementId" => "EnergyEfficiencyClass",
              "value" => "E", "valueDataType" => "xsd:string" }
          ] }
      ]
    }
  end

  before { allow(DidOyd).to receive(:assert_endpoint_host!).and_return(true) }

  def create_dpp!
    post "/dpp/v1/dpps", params: dpp_document.to_json, headers: auth
    expect(response).to have_http_status(:created)
  end

  describe "every change asks for a fresh commitment" do
    it "after CreateDPP" do
      create_dpp!

      expect(PayloadCommitment).to have_received(:call).once
    end

    it "after UpdateDPP" do
      create_dpp!
      patch "/dpp/v1/dpps/#{enc_dpp}", params: { "dppStatus" => "Active" }.to_json,
                                       headers: patch_headers
      expect(response).to have_http_status(:ok)

      expect(PayloadCommitment).to have_received(:call).twice
    end

    it "after UpdateDataElementCollection" do
      create_dpp!
      patch "/dpp/v1/dpps/#{enc_dpp}/collections/EnergyPerformance",
            params: { "elements" => [] }.to_json, headers: patch_headers
      expect(response).to have_http_status(:ok)

      expect(PayloadCommitment).to have_received(:call).twice
    end

    it "after UpdateDataElement" do
      create_dpp!
      patch "/dpp/v1/dpps/#{enc_dpp}/elements/EnergyPerformance/EnergyEfficiencyClass",
            params: { "value" => "D" }.to_json, headers: patch_headers
      expect(response).to have_http_status(:ok)

      expect(PayloadCommitment).to have_received(:call).twice
    end
  end

  # In headers, because the DPP document carries the attributes of EN 18223:2026
  # Table 1 and nothing else -- a proprietary field would break conformance for
  # every reader.
  describe "every read says which state the passport is in" do
    before do
      create_dpp!
      Dpp.find(dpp_id).update_columns(payload_hash: "zPAY", did_commit_state: "stale")
    end

    it "on ReadDPPById" do
      get "/dpp/v1/dpps/#{enc_dpp}"

      expect(response).to have_http_status(:ok)
      expect(response.headers["X-DPP-Payload-Hash"]).to eq("zPAY")
      expect(response.headers["X-DPP-Commit-State"]).to eq("stale")
    end

    it "on ReadDPPByProductId" do
      get "/dpp/v1/dppsByProductId/#{enc_prod}"

      expect(response).to have_http_status(:ok)
      expect(response.headers["X-DPP-Commit-State"]).to eq("stale")
    end

    it "on ReadDataElementCollection" do
      get "/dpp/v1/dpps/#{enc_dpp}/collections/EnergyPerformance"

      expect(response).to have_http_status(:ok)
      expect(response.headers["X-DPP-Commit-State"]).to eq("stale")
    end

    it "on ReadDataElement" do
      get "/dpp/v1/dpps/#{enc_dpp}/elements/EnergyPerformance/EnergyEfficiencyClass"

      expect(response).to have_http_status(:ok)
      expect(response.headers["X-DPP-Commit-State"]).to eq("stale")
    end

    it "keeps the document itself free of the commitment" do
      get "/dpp/v1/dpps/#{enc_dpp}"

      body = JSON.parse(response.body)
      expect(body.keys).not_to include("payloadHash", "didCommitState")
    end
  end

  # Variant B: the service holds no document key, so no write of its own can ever
  # turn `pending` into `committed`. The read path is where the state moves.
  describe "a passport waiting for the holder to sign" do
    before do
      create_dpp!
      Dpp.find(dpp_id).update_columns(payload_hash: "zPAY",
                                      did_commit_state: PayloadCommitment::PENDING)
    end

    it "is re-checked on a read" do
      get "/dpp/v1/dpps/#{enc_dpp}"

      expect(response).to have_http_status(:ok)
      expect(PayloadCommitment).to have_received(:refresh).with(
        having_attributes(dpp_id: dpp_id)
      )
    end

    it "reports the expected hash while it waits" do
      get "/dpp/v1/dpps/#{enc_dpp}"

      expect(response.headers["X-DPP-Payload-Hash"]).to eq("zPAY")
      expect(response.headers["X-DPP-Commit-State"]).to eq(PayloadCommitment::PENDING)
    end

    # A committed passport is not worth a DID resolution on every read.
    it "is not re-checked once it is committed" do
      Dpp.find(dpp_id).update_column(:did_commit_state, PayloadCommitment::COMMITTED)

      get "/dpp/v1/dpps/#{enc_dpp}"

      expect(PayloadCommitment).not_to have_received(:refresh)
    end
  end

  # Nothing is asserted about a passport that has never been through a
  # commitment -- the ones that predate this say nothing rather than "pending".
  it "says nothing when there is nothing to say" do
    create_dpp!

    get "/dpp/v1/dpps/#{enc_dpp}"

    expect(response.headers).not_to have_key("X-DPP-Commit-State")
    expect(response.headers).not_to have_key("X-DPP-Payload-Hash")
  end
end
