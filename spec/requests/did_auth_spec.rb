# frozen_string_literal: true

require "rails_helper"

# prEN 18239: with verified tokens a passport belongs to the DID that created
# it, and only that DID may change it. Signature verification alone would not
# achieve this — it establishes *who* is calling, not *what* they may touch.
#
# DidTokenVerifier itself is covered in spec/services; here it is stubbed so
# these examples are about the controller wiring.
RSpec.describe "DID-based authorization", type: :request do
  let(:owner)     { "did:oyd:zOwnerAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA" }
  let(:stranger)  { "did:oyd:zStrangerBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB" }
  let(:dpp_id)    { "did:oyd:zQmeEMs9XtQgPaLT7t3sMuqRkYSDtonkQ9xFcJVMKtMGx1C" }
  let(:product_id) { "https://id.lumina.example/01/09520123456788" }

  # A real (unsigned) JWT, so the same headers work in both modes: permissive
  # decodes it as-is, and the stubbed verifier below reads the same claims.
  def headers_for(did)
    token = JWT.encode({ "iss" => did, "sub" => did }, nil, "none")
    { "Content-Type" => "application/json", "Authorization" => "Bearer #{token}" }
  end

  def document(overrides = {})
    { "DigitalProductPassportID" => dpp_id,
      "ProductID" => product_id,
      "Granularity" => "model",
      "DPPSchemaVersion" => "prEN 18223:2025",
      "EconomicOperatorID" => "did:oyd:zQmPPwHJK1NHBz3BS89StWsfrH4pzkyqwJiK94zVj25wXUS" }.merge(overrides)
  end

  before do
    allow(DidTokenVerifier).to receive(:enabled?).and_return(true)
    allow(DidTokenVerifier).to receive(:call) do |token|
      claims = begin
        JWT.decode(token.to_s, nil, false).first
      rescue JWT::DecodeError
        nil
      end
      claims if claims && claims["iss"].to_s.start_with?("did:")
    end
  end

  describe "CreateDPP" do
    it "records the presenting DID as the owner" do
      post "/dpp/v1/dpps", params: document.to_json, headers: headers_for(owner)

      expect(response).to have_http_status(:created)
      expect(Dpp.find(dpp_id).owner_did).to eq(owner)
    end

    it "does not take the owner from the payload" do
      post "/dpp/v1/dpps", params: document("owner_did" => stranger).to_json,
                           headers: headers_for(owner)

      expect(Dpp.find(dpp_id).owner_did).to eq(owner)
    end

    it "still rejects a token that does not verify" do
      post "/dpp/v1/dpps", params: document.to_json,
                           headers: { "Content-Type" => "application/json",
                                      "Authorization" => "Bearer garbage" }

      expect(response).to have_http_status(:unauthorized)
      expect(response.parsed_body["statusCode"]).to eq("ClientNotAuthorized")
    end
  end

  describe "writes on an existing passport" do
    before { post "/dpp/v1/dpps", params: document.to_json, headers: headers_for(owner) }

    let(:enc) { CGI.escape(dpp_id) }
    let(:patch_headers) do
      ->(did) { headers_for(did).merge("Content-Type" => "application/merge-patch+json") }
    end

    it "lets the owner update" do
      patch "/dpp/v1/dpps/#{enc}", params: { "FacilityID" => "https://f.example/1" }.to_json,
                                   headers: patch_headers.call(owner)
      expect(response).to have_http_status(:ok)
    end

    it "refuses an update from another DID" do
      patch "/dpp/v1/dpps/#{enc}", params: { "FacilityID" => "https://f.example/2" }.to_json,
                                   headers: patch_headers.call(stranger)

      expect(response).to have_http_status(:forbidden)
      expect(response.parsed_body["statusCode"]).to eq("ClientForbidden")
      expect(Dpp.find(dpp_id).to_document[:FacilityID]).to be_nil
    end

    it "refuses a delete from another DID and keeps the passport" do
      delete "/dpp/v1/dpps/#{enc}", headers: headers_for(stranger)

      expect(response).to have_http_status(:forbidden)
      expect(Dpp.exists?(dpp_id)).to be(true)
    end

    it "refuses a data element patch from another DID" do
      patch "/dpp/v1/dpps/#{enc}/elements/dataElementCollections/X/DataElements/Y",
            params: { "Value" => "D" }.to_json, headers: patch_headers.call(stranger)

      expect(response).to have_http_status(:forbidden)
    end

    it "lets the owner delete" do
      delete "/dpp/v1/dpps/#{enc}", headers: headers_for(owner)
      expect(response).to have_http_status(:no_content)
    end
  end

  describe "a passport created before verification was switched on" do
    before do
      Dpp.create!(dpp_id: dpp_id, product_id: product_id, dpp_schema_version: "prEN 18223:2025",
                  economic_operator_id: "did:oyd:zQmPPwHJK1NHBz3BS89StWsfrH4pzkyqwJiK94zVj25wXUS", last_update: Time.now.utc,
                  content: {}, owner_did: nil)
    end

    it "cannot be modified, because there is nobody to compare against" do
      patch "/dpp/v1/dpps/#{CGI.escape(dpp_id)}",
            params: { "FacilityID" => "https://f.example/3" }.to_json,
            headers: headers_for(owner).merge("Content-Type" => "application/merge-patch+json")

      expect(response).to have_http_status(:forbidden)
      expect(response.parsed_body["message"].first["text"]).to match(/no recorded owner/)
    end
  end

  describe "permissive mode (default)" do
    before { allow(DidTokenVerifier).to receive(:enabled?).and_return(false) }

    it "records no owner and enforces none" do
      post "/dpp/v1/dpps", params: document.to_json, headers: headers_for(owner)
      expect(Dpp.find(dpp_id).owner_did).to be_nil

      patch "/dpp/v1/dpps/#{CGI.escape(dpp_id)}",
            params: { "FacilityID" => "https://f.example/4" }.to_json,
            headers: headers_for(stranger).merge("Content-Type" => "application/merge-patch+json")
      expect(response).to have_http_status(:ok)
    end
  end
end
