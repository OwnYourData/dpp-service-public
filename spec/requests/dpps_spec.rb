# frozen_string_literal: true

require "rails_helper"

# Request specs for the prEN 18222 Life Cycle API (Clause 4), the Registry API
# (Clause 5) and the Fine Granular API (Clause 6), using a lighting DPP.
RSpec.describe "DPP API", type: :request do
  # The bearer gate decodes the JWT (signature verification is still TODO), so
  # the token must be a structurally valid JWT — a placeholder string yields 401.
  let(:token) { "Bearer #{JWT.encode({ sub: 'did:oyd:zQmPPwHJK1NHBz3BS89StWsfrH4pzkyqwJiK94zVj25wXUS', scope: 'dpp:write' }, nil, 'none')}" }
  let(:json)  { { "Content-Type" => "application/json" } }
  let(:auth)  { json.merge("Authorization" => token) }
  let(:patch_headers) { auth.merge("Content-Type" => "application/merge-patch+json") }

  # Identifiers are URLs (prEN 18219): they contain ":", "/" and ".".
  let(:dpp_id)     { "https://dpp.lumina.example/01/09520123456788/8546" }
  let(:product_id) { "https://id.lumina.example/01/09520123456788" }
  let(:enc_dpp)    { CGI.escape(dpp_id) }
  let(:enc_prod)   { CGI.escape(product_id) }

  let(:dpp_document) do
    {
      "DigitalProductPassportID" => dpp_id,
      "ProductID" => product_id,
      "Granularity" => "model",
      "DPPSchemaVersion" => "prEN 18223:2025",
      "DPPStatus" => "Active",
      "EconomicOperatorID" => "did:oyd:zQmPPwHJK1NHBz3BS89StWsfrH4pzkyqwJiK94zVj25wXUS",
      "dataElementCollections" => [
        {
          "ElementId" => "EnergyPerformance",
          "Name" => "Energieeffizienz",
          "DataElements" => [
            { "@type" => "SinglevaluedDataElement", "ElementId" => "LuminousFlux",
              "Name" => "Lichtstrom", "Value" => 806, "ValueDataType" => "xs:integer",
              "UnitOfMeasure" => "lm" },
            { "@type" => "SinglevaluedDataElement", "ElementId" => "EnergyEfficiencyClass",
              "Name" => "Energieeffizienzklasse", "Value" => "E", "ValueDataType" => "xs:string" }
          ]
        }
      ]
    }
  end

  def create_dpp!
    post "/dpp/v1/dpps", params: dpp_document.to_json, headers: auth
    expect(response).to have_http_status(:created)
  end

  def efficiency_class_path
    "/dpp/v1/dpps/#{enc_dpp}/elements/" \
      "dataElementCollections/EnergyPerformance/DataElements/EnergyEfficiencyClass"
  end

  describe "Life Cycle API (Clause 4)" do
    # Regression: the default Rails segment constraint /[^.\/?]+/ made every
    # URL-shaped identifier (it contains dots) unroutable — 404.
    it "creates and reads a DPP whose identifier is a URL" do
      create_dpp!

      get "/dpp/v1/dpps/#{enc_dpp}"
      expect(response).to have_http_status(:ok)
      body = JSON.parse(response.body)
      expect(body["DigitalProductPassportID"]).to eq(dpp_id)
      expect(body["ProductID"]).to eq(product_id)
    end

    it "reads a DPP by its product identifier" do
      create_dpp!

      get "/dpp/v1/dppsByProductId/#{enc_prod}"
      expect(response).to have_http_status(:ok)
      expect(JSON.parse(response.body)["DigitalProductPassportID"]).to eq(dpp_id)
    end

    it "resolves product identifiers to DPP identifiers" do
      create_dpp!

      post "/dpp/v1/dppsByProductIds", params: [product_id].to_json, headers: json
      expect(response).to have_http_status(:ok)
      body = JSON.parse(response.body)
      expect(body["statusCode"]).to eq("Success")
      expect(body["payload"]).to eq([dpp_id])
    end

    it "applies an RFC 7396 merge patch to the DPP" do
      create_dpp!

      patch "/dpp/v1/dpps/#{enc_dpp}",
            params: { "FacilityID" => "https://id.lumina.example/414/0952012345002" }.to_json,
            headers: patch_headers

      expect(response).to have_http_status(:ok)
      expect(JSON.parse(response.body)["FacilityID"]).to end_with("0952012345002")
    end

    it "rejects writes without a bearer token" do
      post "/dpp/v1/dpps", params: dpp_document.to_json, headers: json
      expect(response).to have_http_status(:unauthorized)
    end

    it "returns a Result object with 404 for an unknown DPP" do
      get "/dpp/v1/dpps/#{CGI.escape('urn:unknown')}"
      expect(response).to have_http_status(:not_found)
      expect(JSON.parse(response.body)["statusCode"]).to eq("ClientErrorResourceNotFound")
    end
  end

  describe "Fine Granular API (Clause 6)" do
    before { create_dpp! }

    it "reads a data element collection" do
      get "/dpp/v1/dpps/#{enc_dpp}/collections/EnergyPerformance"
      expect(response).to have_http_status(:ok)
      expect(JSON.parse(response.body)["DataElements"].size).to eq(2)
    end

    it "reads a single data element by its ElementId path" do
      get "/dpp/v1/dpps/#{enc_dpp}/elements/" \
          "dataElementCollections/EnergyPerformance/DataElements/LuminousFlux"

      expect(response).to have_http_status(:ok)
      body = JSON.parse(response.body)
      expect(body["Value"]).to eq(806)
      expect(body["UnitOfMeasure"]).to eq("lm")
    end

    # Regression: assign_path indexed the DataElements array with a String and
    # raised TypeError -> 500.
    it "patches a single data element inside a collection" do
      patch efficiency_class_path, params: { "Value" => "D" }.to_json, headers: patch_headers

      expect(response).to have_http_status(:ok)
      expect(JSON.parse(response.body)["Value"]).to eq("D")

      get efficiency_class_path
      expect(JSON.parse(response.body)["Value"]).to eq("D")
    end

    it "returns 404 for an unknown element path" do
      get "/dpp/v1/dpps/#{enc_dpp}/elements/dataElementCollections/Nope/DataElements/Nope"
      expect(response).to have_http_status(:not_found)
    end

    it "patches a data element collection" do
      patch "/dpp/v1/dpps/#{enc_dpp}/collections/EnergyPerformance",
            params: { "Name" => "Energieeffizienz (2026)" }.to_json,
            headers: patch_headers

      expect(response).to have_http_status(:ok)
      expect(JSON.parse(response.body)["Name"]).to eq("Energieeffizienz (2026)")
    end
  end

  describe "Archiving (prEN 18221 / Module 6)" do
    before { create_dpp! }

    it "archives the previous state and serves it by date" do
      before_change = Time.now.utc

      patch efficiency_class_path, params: { "Value" => "D" }.to_json, headers: patch_headers
      expect(response).to have_http_status(:ok)

      get "/dpp/v1/dppsByProductIdAndDate/#{enc_prod}", params: { date: before_change.iso8601 }
      expect(response).to have_http_status(:ok)

      element = JSON.parse(response.body)["dataElementCollections"]
                    .find { |c| c["ElementId"] == "EnergyPerformance" }["DataElements"]
                    .find { |e| e["ElementId"] == "EnergyEfficiencyClass" }
      expect(element["Value"]).to eq("E") # the value *before* the patch
    end

    # Regression: dpp_versions was dependent: :destroy, so DeleteDPPById wiped
    # the history it had just written.
    it "keeps the archived history after DeleteDPPById" do
      deleted_at = Time.now.utc

      delete "/dpp/v1/dpps/#{enc_dpp}", headers: auth
      expect(response).to have_http_status(:no_content)

      get "/dpp/v1/dpps/#{enc_dpp}"
      expect(response).to have_http_status(:not_found)

      get "/dpp/v1/dppsByProductIdAndDate/#{enc_prod}", params: { date: deleted_at.iso8601 }
      expect(response).to have_http_status(:ok)
      body = JSON.parse(response.body)
      expect(body["DigitalProductPassportID"]).to eq(dpp_id)
      expect(body["DPPStatus"]).to eq("Archived")
    end

    it "rejects an invalid date" do
      get "/dpp/v1/dppsByProductIdAndDate/#{enc_prod}", params: { date: "gestern" }
      expect(response).to have_http_status(:bad_request)
      expect(JSON.parse(response.body)["statusCode"]).to eq("ClientErrorBadRequest")
    end
  end

  describe "Registry API (Clause 5)" do
    it "registers a DPP and returns a registry identifier" do
      post "/dpp/v1/registerDPP",
           params: { "ProductID" => product_id, "OperatorID" => "did:oyd:zQmPPwHJK1NHBz3BS89StWsfrH4pzkyqwJiK94zVj25wXUS" }.to_json,
           headers: auth

      expect(response).to have_http_status(:created)
      body = JSON.parse(response.body)
      expect(body["statusCode"]).to eq("SuccessCreated")
      expect(body["registryIdentifier"]).to start_with("urn:ec:dpp:registry:")
    end

    it "requires ProductID and OperatorID" do
      post "/dpp/v1/registerDPP", params: { "ProductID" => product_id }.to_json, headers: auth
      expect(response).to have_http_status(:bad_request)
    end
  end
end
