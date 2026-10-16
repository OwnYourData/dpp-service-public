# frozen_string_literal: true

require "rails_helper"

# EN 18222:2026 8.1: GET, POST and PATCH take an optional "representation" query
# flag with the values "compressed" (the default, EN 18223:2026 5.2) and "full"
# (EN 18223:2026 Annex A). The norm names no other value; this service refuses
# any other with 400 and the Result object (Tables 12 and 15).
RSpec.describe "Representation flag (EN 18222:2026 8.1)", type: :request do
  let(:token) { "Bearer #{JWT.encode({ sub: 'did:oyd:zQmPPwHJK1NHBz3BS89StWsfrH4pzkyqwJiK94zVj25wXUS', scope: 'dpp:write' }, nil, 'none')}" }
  let(:auth)  { { "Content-Type" => "application/json", "Authorization" => token } }
  let(:patch_headers) { auth.merge("Content-Type" => "application/merge-patch+json") }

  let(:dpp_id)     { "https://dpp.lumina.example/01/09520123456788/21/000001" }
  let(:product_id) { "https://dpp.lumina.example/01/09520123456788/21/000001" }
  let(:enc_dpp)    { CGI.escape(dpp_id) }

  # Shaped like the reference passport behind dpp.oydapp.eu/01/09520123456788/21/000001.
  let(:dpp_document) do
    {
      "digitalProductPassportId" => dpp_id,
      "uniqueProductIdentifier" => product_id,
      "granularity" => "item",
      "dppSchemaVersion" => "EN 18223:2026",
      "dppStatus" => "Active",
      "economicOperatorId" => "did:oyd:zQmX493GLVxE8Wasc8ANTdZmq4YUsvdk5j6Daf7iQaPECt6",
      "elements" => [
        { "elementId" => "ProductIdentification", "objectType" => "DataElementCollection",
          "dictionaryReference" => "https://dict.example.org/dpp/lighting/ProductIdentification",
          "elements" => [
            { "elementId" => "ModelIdentifier", "objectType" => "SingleValuedDataElement",
              "valueDataType" => "xsd:string", "value" => "LUM-A60-827-806" },
            { "elementId" => "SerialNumber", "objectType" => "SingleValuedDataElement",
              "valueDataType" => "xsd:string", "value" => "000001" }
          ] },
        { "elementId" => "EnergyPerformance", "objectType" => "DataElementCollection",
          "elements" => [
            { "elementId" => "OnModePower", "objectType" => "SingleValuedDataElement",
              "valueDataType" => "xsd:decimal", "unitOfMeasure" => "W", "value" => 8.5 },
            { "elementId" => "LuminousFlux", "objectType" => "SingleValuedDataElement",
              "valueDataType" => "xsd:integer", "unitOfMeasure" => "lm", "value" => 806 }
          ] },
        { "elementId" => "ColourTemperatures", "objectType" => "MultiValuedDataElement",
          "elements" => [
            { "elementId" => "t1", "objectType" => "SingleValuedDataElement", "value" => 2700 },
            { "elementId" => "t2", "objectType" => "SingleValuedDataElement", "value" => 4000 }
          ] }
      ]
    }
  end

  let(:compressed_data) do
    {
      "ProductIdentification" => { "ModelIdentifier" => "LUM-A60-827-806", "SerialNumber" => "000001" },
      "EnergyPerformance" => { "OnModePower" => 8.5, "LuminousFlux" => 806 },
      "ColourTemperatures" => [2700, 4000]
    }
  end

  let(:unknown_values) { ["bogus", "", "Full", "FULL", "Compressed", "COMPRESSED", "expanded"] }

  def body = JSON.parse(response.body)

  def create_dpp!(query = "")
    post "/dpp/v1/dpps#{query}", params: dpp_document.to_json, headers: auth
  end

  def expect_compressed(document)
    expect(document).not_to have_key("elements")
    expect(document["digitalProductPassportId"]).to eq(dpp_id)
    expect(document).to include(compressed_data)
  end

  def expect_full(document)
    expect(document["elements"]).to eq(dpp_document["elements"])
    expect(document["digitalProductPassportId"]).to eq(dpp_id)
  end

  def expect_bad_representation
    expect(response).to have_http_status(:bad_request)
    expect(response.media_type).to eq("application/json")
    expect(body["statusCode"]).to eq("ClientErrorBadRequest")
    expect(body["message"].first["messageType"]).to eq("Error")
    expect(body["message"].first["text"]).to include("representation", "EN 18222:2026 8.1")
  end

  # Paths of the read methods, each taking the flag as a query parameter.
  def read_paths
    {
      "ReadDPPById" => "/dpp/v1/dpps/#{enc_dpp}",
      "ReadDPPByProductId" => "/dpp/v1/dppsByProductId/#{CGI.escape(product_id)}",
      "ReadDPPVersionByIdAndDate" => "/dpp/v1/dppsByIdAndDate/#{enc_dpp}?date=#{CGI.escape(1.minute.from_now.utc.iso8601)}"
    }
  end

  def with_flag(path, value)
    "#{path}#{path.include?('?') ? '&' : '?'}representation=#{CGI.escape(value)}"
  end

  describe "the read methods for a whole passport" do
    before do
      create_dpp!
      expect(response).to have_http_status(:created)
    end

    %w[ReadDPPById ReadDPPByProductId ReadDPPVersionByIdAndDate].each do |method|
      describe method do
        it "answers in the compressed form without the flag" do
          get read_paths.fetch(method)
          expect(response).to have_http_status(:ok)
          expect_compressed(body)
        end

        it "answers in the compressed form with representation=compressed" do
          get with_flag(read_paths.fetch(method), "compressed")
          expect(response).to have_http_status(:ok)
          expect_compressed(body)
        end

        it "answers in the full form with representation=full" do
          get with_flag(read_paths.fetch(method), "full")
          expect(response).to have_http_status(:ok)
          expect_full(body)
        end

        it "refuses any other value, other spellings included, with 400 and the Result object" do
          unknown_values.each do |value|
            get with_flag(read_paths.fetch(method), value)
            expect_bad_representation
          end
        end
      end
    end

    it "keeps every header attribute of EN 18223:2026 Table 1 in the compressed form" do
      get "/dpp/v1/dpps/#{enc_dpp}"
      expect(body.keys).to include("digitalProductPassportId", "uniqueProductIdentifier", "granularity",
                                   "dppSchemaVersion", "dppStatus", "lastUpdated", "economicOperatorId")
    end

    it "is the same passport in both forms" do
      get with_flag("/dpp/v1/dpps/#{enc_dpp}", "full")
      full = body
      get "/dpp/v1/dpps/#{enc_dpp}"

      expect(body).to eq(DppRepresentation.passport(full, "compressed"))
    end
  end

  # What the planned dpp-criteria check DPP-API-023 looks at.
  describe "the checks of DPP-API-023" do
    before { create_dpp! }

    it "holds for ReadDPPById" do
      get "/dpp/v1/dpps/#{enc_dpp}"
      expect(body).not_to have_key("elements")
      expect(body["digitalProductPassportId"]).to eq(dpp_id)

      get "/dpp/v1/dpps/#{enc_dpp}?representation=full"
      expect(body).to have_key("elements")

      get "/dpp/v1/dpps/#{enc_dpp}?representation=compressed"
      expect(body).not_to have_key("elements")

      get "/dpp/v1/dpps/#{enc_dpp}?representation=unknown"
      expect(response).to have_http_status(:bad_request)
    end
  end

  describe "HEAD and unknown passports" do
    before { create_dpp! }

    it "answers HEAD on ReadDPPById with 200 and no body" do
      head "/dpp/v1/dpps/#{enc_dpp}"
      expect(response).to have_http_status(:ok)
      expect(response.body).to be_empty
    end

    it "answers HEAD with an unknown flag with 400" do
      head "/dpp/v1/dpps/#{enc_dpp}?representation=bogus"
      expect(response).to have_http_status(:bad_request)
    end

    it "answers an unknown dppId with 404 and the Result object, in either form" do
      ["", "?representation=full"].each do |query|
        get "/dpp/v1/dpps/#{CGI.escape('did:oyd:zQmUnknown')}#{query}"
        expect(response).to have_http_status(:not_found)
        expect(body["statusCode"]).to eq("ClientErrorResourceNotFound")
        expect(body["message"].first["messageType"]).to eq("Error")
      end
    end
  end

  describe "ReadDataElement" do
    before { create_dpp! }

    def element(path, query = "")
      get "/dpp/v1/dpps/#{enc_dpp}/elements/#{ERB::Util.url_encode(path)}#{query}"
    end

    it "answers a single value with the bare JSON value in the compressed form" do
      element("$.ProductIdentification.ModelIdentifier")
      expect(response).to have_http_status(:ok)
      expect(response.media_type).to eq("application/json")
      expect(response.body).to eq('"LUM-A60-827-806"')
    end

    it "answers a collection with its compressed object and a list with its array" do
      element("$.EnergyPerformance")
      expect(body).to eq("OnModePower" => 8.5, "LuminousFlux" => 806)

      element("$.ColourTemperatures")
      expect(body).to eq([2700, 4000])

      element("$.ColourTemperatures[1]")
      expect(body).to eq(4000)
    end

    it "evaluates the path on the compressed form: the answer is what the path selects there" do
      get "/dpp/v1/dpps/#{enc_dpp}"
      passport = body

      ["$.ProductIdentification.SerialNumber", "$.EnergyPerformance", "$['EnergyPerformance']['LuminousFlux']",
       "$.ColourTemperatures[-1]"].each do |path|
        element(path)
        expect(body).to eq(ElementIdPath.parse(path).resolve(passport))
      end
    end

    it "answers with the element object of Annex A in the full form" do
      element("$.EnergyPerformance.LuminousFlux", "?representation=full")
      expect(body).to eq("elementId" => "LuminousFlux", "objectType" => "SingleValuedDataElement",
                         "valueDataType" => "xsd:integer", "unitOfMeasure" => "lm", "value" => 806)
    end

    it "refuses an unknown value with 400" do
      unknown_values.each do |value|
        element("$.EnergyPerformance.LuminousFlux", "?representation=#{CGI.escape(value)}")
        expect_bad_representation
      end
    end
  end

  describe "the answers of POST and PATCH" do
    it "CreateDPP answers in the compressed form by default" do
      create_dpp!
      expect(response).to have_http_status(:created)
      expect_compressed(body)
    end

    it "CreateDPP answers in the full form with representation=full" do
      create_dpp!("?representation=full")
      expect(response).to have_http_status(:created)
      expect_full(body)
    end

    it "CreateDPP with an unknown value is refused before anything is created" do
      expect(DidOyd).not_to receive(:mint)
      create_dpp!("?representation=Full")

      expect_bad_representation
      expect(Dpp.count).to eq(0)
    end

    context "with a passport" do
      before { create_dpp! }

      it "UpdateDPP answers in the requested form" do
        patch "/dpp/v1/dpps/#{enc_dpp}", params: { "facilityId" => "https://id.lumina.example/414/0952012345009" }.to_json,
                                         headers: patch_headers
        expect(response).to have_http_status(:ok)
        expect_compressed(body)
        expect(body["facilityId"]).to eq("https://id.lumina.example/414/0952012345009")

        patch "/dpp/v1/dpps/#{enc_dpp}?representation=full", params: { "dppStatus" => "Active" }.to_json,
                                                             headers: patch_headers
        expect_full(body)
      end

      it "UpdateDPP with an unknown value changes nothing" do
        patch "/dpp/v1/dpps/#{enc_dpp}?representation=bogus", params: { "facilityId" => "x:y" }.to_json,
                                                              headers: patch_headers
        expect_bad_representation

        get "/dpp/v1/dpps/#{enc_dpp}"
        expect(body).not_to have_key("facilityId")
      end

      it "UpdateDataElement answers with the element in the requested form" do
        path = "/dpp/v1/dpps/#{enc_dpp}/elements/#{ERB::Util.url_encode('$.EnergyPerformance.LuminousFlux')}"

        patch path, params: { "value" => 810 }.to_json, headers: patch_headers
        expect(response).to have_http_status(:ok)
        expect(response.body).to eq("810")

        patch "#{path}?representation=full", params: { "value" => 811 }.to_json, headers: patch_headers
        expect(body).to include("elementId" => "LuminousFlux", "value" => 811)

        patch "#{path}?representation=bogus", params: { "value" => 1 }.to_json, headers: patch_headers
        expect_bad_representation
        get path
        expect(body).to eq(811)
      end

      it "reads the flag from the query string only, never from a JSON body" do
        patch "/dpp/v1/dpps/#{enc_dpp}", params: { "representation" => "bogus" }.to_json, headers: patch_headers
        expect(response).to have_http_status(:ok)
      end
    end
  end

  describe "methods that return no passport" do
    before { create_dpp! }

    it "ignores the flag on ReadDPPIdsByProductIds, whose payload is a list of identifiers" do
      post "/dpp/v1/dppsByProductIds?representation=bogus", params: [product_id].to_json, headers: auth
      expect(response).to have_http_status(:ok)
      expect(body["payload"]).to eq([dpp_id])
    end
  end
end
