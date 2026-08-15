# frozen_string_literal: true

require "rails_helper"

# Variante A: the DPP Service mints a did:oyd when no DigitalProductPassportID
# is supplied. DidOyd is stubbed so these specs need neither libsodium nor
# network access to the VDR.
RSpec.describe "CreateDPP with did:oyd (Variante A)", type: :request do
  let(:token) { "Bearer #{JWT.encode({ sub: 'did:web:lumina.example', scope: 'dpp:write' }, nil, 'none')}" }
  let(:auth)  { { "Content-Type" => "application/json", "Authorization" => token } }

  let(:product_id) { "https://id.lumina.example/01/09520123456788" }
  let(:minted) do
    { did: "did:oyd:zTESThash123456", doc_key: "doc-secret", rev_key: "rev-secret", rev_log: "rev-log" }
  end

  # DPP document WITHOUT DigitalProductPassportID -> triggers minting.
  let(:doc_without_id) do
    {
      "ProductID" => product_id,
      "Granularity" => "model",
      "DPPSchemaVersion" => "prEN 18223:2025",
      "EconomicOperatorID" => "did:web:lumina.example"
    }
  end

  describe "minting" do
    before { allow(DidOyd).to receive(:mint).with(product_id).and_return(minted) }

    it "mints a did:oyd and returns it as the DPP identifier" do
      post "/dpp/v1/dpps", params: doc_without_id.to_json, headers: auth

      expect(response).to have_http_status(:created)
      expect(DidOyd).to have_received(:mint).with(product_id)
      expect(JSON.parse(response.body)["DigitalProductPassportID"]).to eq(minted[:did])
    end

    it "marks the DPP as did_managed and stores the keys encrypted" do
      post "/dpp/v1/dpps", params: doc_without_id.to_json, headers: auth
      expect(response).to have_http_status(:created)

      dpp = Dpp.find(minted[:did])
      expect(dpp.did_managed).to be(true)
      # ciphertext at rest differs from the plaintext...
      expect(dpp.did_doc_key_enc).to be_present
      expect(dpp.did_doc_key_enc).not_to include("doc-secret")
      # ...but round-trips through KeyVault
      expect(dpp.did_doc_key).to eq("doc-secret")
      expect(dpp.did_rev_key).to eq("rev-secret")
    end

    it "never leaks the private keys in the response document" do
      post "/dpp/v1/dpps", params: doc_without_id.to_json, headers: auth
      expect(response.body).not_to include("doc-secret")
      expect(response.body).not_to include("rev-secret")
    end

    it "requires a ProductID to mint" do
      post "/dpp/v1/dpps", params: doc_without_id.except("ProductID").to_json, headers: auth
      expect(response).to have_http_status(:bad_request)
    end

    it "surfaces a VDR failure as 502" do
      allow(DidOyd).to receive(:mint).and_raise(DidOyd::DidError, "VDR unreachable")
      post "/dpp/v1/dpps", params: doc_without_id.to_json, headers: auth
      expect(response).to have_http_status(:bad_gateway)
      expect(JSON.parse(response.body)["statusCode"]).to eq("ServerErrorBadGateway")
    end
  end

  describe "DID normalization (default repo)" do
    it "strips the @default-location suffix" do
      expect(DidOyd.normalize_did("did:oyd:zABC@https://oydid.ownyourdata.eu")).to eq("did:oyd:zABC")
    end

    it "strips the percent-encoded default-location suffix" do
      expect(DidOyd.normalize_did("did:oyd:zABC@https%3A%2F%2Foydid.ownyourdata.eu")).to eq("did:oyd:zABC")
    end

    it "leaves a bare did:oyd untouched" do
      expect(DidOyd.normalize_did("did:oyd:zABC")).to eq("did:oyd:zABC")
    end
  end

  describe "client-supplied identifier" do
    it "does NOT mint when a DigitalProductPassportID is provided" do
      expect(DidOyd).not_to receive(:mint)
      body = doc_without_id.merge("DigitalProductPassportID" => "did:oyd:zPREEXISTING")
      post "/dpp/v1/dpps", params: body.to_json, headers: auth

      expect(response).to have_http_status(:created)
      dpp = Dpp.find("did:oyd:zPREEXISTING")
      expect(dpp.did_managed).to be(false)
    end
  end

  describe "DeleteDPPById revokes a managed DID" do
    before do
      allow(DidOyd).to receive(:mint).with(product_id).and_return(minted)
      allow(DidOyd).to receive(:revoke)
      post "/dpp/v1/dpps", params: doc_without_id.to_json, headers: auth
    end

    it "calls DidOyd.revoke with the stored keys before deleting" do
      delete "/dpp/v1/dpps/#{CGI.escape(minted[:did])}", headers: auth

      expect(response).to have_http_status(:no_content)
      expect(DidOyd).to have_received(:revoke)
        .with(minted[:did], doc_key: "doc-secret", rev_key: "rev-secret")
    end
  end
end
