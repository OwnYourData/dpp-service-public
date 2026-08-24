# frozen_string_literal: true

require "rails_helper"

# Variante A: the DPP Service mints a did:oyd when no DigitalProductPassportID
# is supplied. DidOyd is stubbed so these specs need neither libsodium nor
# network access to the VDR.
RSpec.describe "CreateDPP with did:oyd (Variante A)", type: :request do
  let(:token) { "Bearer #{JWT.encode({ sub: 'did:oyd:zQmPPwHJK1NHBz3BS89StWsfrH4pzkyqwJiK94zVj25wXUS', scope: 'dpp:write' }, nil, 'none')}" }
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
      "EconomicOperatorID" => "did:oyd:zQmPPwHJK1NHBz3BS89StWsfrH4pzkyqwJiK94zVj25wXUS"
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

  # Variante B: the operator minted the identifier itself. The service holds no
  # key for it, so whatever is wrong with it at creation stays wrong -- which is
  # why it is checked here and nowhere later.
  describe "client-supplied identifier" do
    let(:body) { doc_without_id.merge("DigitalProductPassportID" => "did:oyd:zPREEXISTING") }

    it "does NOT mint when a DigitalProductPassportID is provided" do
      allow(DidOyd).to receive(:assert_endpoint_host!).and_return(true)
      expect(DidOyd).not_to receive(:mint)
      post "/dpp/v1/dpps", params: body.to_json, headers: auth

      expect(response).to have_http_status(:created)
      dpp = Dpp.find("did:oyd:zPREEXISTING")
      expect(dpp.did_managed).to be(false)
    end

    it "checks it against the host that will serve the passport" do
      allow(DidOyd).to receive(:assert_endpoint_host!).and_return(true)
      post "/dpp/v1/dpps", params: body.to_json, headers: auth

      expect(DidOyd).to have_received(:assert_endpoint_host!)
        .with("did:oyd:zPREEXISTING", DidOyd.endpoint_base)
    end

    it "refuses an identifier that does not resolve, and creates nothing" do
      allow(DidOyd).to receive(:assert_endpoint_host!)
        .and_raise(DidOyd::DidError.new("did:oyd:zPREEXISTING does not resolve"))

      post "/dpp/v1/dpps", params: body.to_json, headers: auth

      expect(response).to have_http_status(:bad_request)
      expect(response.body).to include("does not resolve")
      expect(Dpp.exists?("did:oyd:zPREEXISTING")).to be(false)
    end

    it "refuses one whose serviceEndpoint sends readers elsewhere" do
      allow(DidOyd).to receive(:assert_endpoint_host!)
        .and_raise(DidOyd::DidError.new("DigitalProductPassportID resolves to other.example, " \
                                        "but this passport is served from here.example"))

      post "/dpp/v1/dpps", params: body.to_json, headers: auth

      expect(response).to have_http_status(:bad_request)
      expect(response.body).to include("other.example")
      expect(Dpp.exists?("did:oyd:zPREEXISTING")).to be(false)
    end

    # An identifier that is not a did:oyd cannot be resolved this way and is
    # stored as before -- the check is about the method we mint with, not a new
    # restriction on what may identify a passport.
    it "leaves a non-did:oyd identifier alone" do
      expect(DidOyd).not_to receive(:assert_endpoint_host!)
      post "/dpp/v1/dpps",
           params: doc_without_id.merge("DigitalProductPassportID" => "https://id.example/p/1").to_json,
           headers: auth

      expect(response).to have_http_status(:created)
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
