# frozen_string_literal: true

require "rails_helper"

# Request specs for the EN 18222:2026 Life Cycle API (Clause 4), the Registry API
# (Clause 5) and the Fine Granular API (Clause 6), using a lighting DPP.
RSpec.describe "DPP API", type: :request do
  # The bearer gate decodes the JWT (signature verification is still TODO), so
  # the token must be a structurally valid JWT — a placeholder string yields 401.
  let(:token) { "Bearer #{JWT.encode({ sub: 'did:oyd:zQmPPwHJK1NHBz3BS89StWsfrH4pzkyqwJiK94zVj25wXUS', scope: 'dpp:write' }, nil, 'none')}" }
  let(:json)  { { "Content-Type" => "application/json" } }
  let(:auth)  { json.merge("Authorization" => token) }
  let(:patch_headers) { auth.merge("Content-Type" => "application/merge-patch+json") }

  # Identifiers are URLs (EN 18219:2026): they contain ":", "/" and ".".
  let(:dpp_id)     { "https://dpp.lumina.example/01/09520123456788/8546" }
  let(:product_id) { "https://id.lumina.example/01/09520123456788" }
  let(:enc_dpp)    { CGI.escape(dpp_id) }
  let(:enc_prod)   { CGI.escape(product_id) }

  let(:dpp_document) do
    {
      "digitalProductPassportId" => dpp_id,
      "uniqueProductIdentifier" => product_id,
      "granularity" => "model",
      "dppSchemaVersion" => "EN 18223:2026",
      "dppStatus" => "Active",
      "economicOperatorId" => "did:oyd:zQmPPwHJK1NHBz3BS89StWsfrH4pzkyqwJiK94zVj25wXUS",
      "elements" => [
        {
          "elementId" => "EnergyPerformance",
          "objectType" => "DataElementCollection",
          "elements" => [
            { "objectType" => "SingleValuedDataElement", "elementId" => "LuminousFlux", "value" => 806, "valueDataType" => "xsd:integer",
              "unitOfMeasure" => "lm" },
            { "objectType" => "SingleValuedDataElement", "elementId" => "EnergyEfficiencyClass", "value" => "E", "valueDataType" => "xsd:string" }
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
    "/dpp/v1/dpps/#{enc_dpp}/elements/EnergyPerformance/EnergyEfficiencyClass"
  end

  describe "Life Cycle API (Clause 4)" do
    # Regression: the default Rails segment constraint /[^.\/?]+/ made every
    # URL-shaped identifier (it contains dots) unroutable — 404.
    it "creates and reads a DPP whose identifier is a URL" do
      create_dpp!

      get "/dpp/v1/dpps/#{enc_dpp}"
      expect(response).to have_http_status(:ok)
      body = JSON.parse(response.body)
      expect(body["digitalProductPassportId"]).to eq(dpp_id)
      expect(body["uniqueProductIdentifier"]).to eq(product_id)
    end

    it "reads a DPP by its product identifier" do
      create_dpp!

      get "/dpp/v1/dppsByProductId/#{enc_prod}"
      expect(response).to have_http_status(:ok)
      expect(JSON.parse(response.body)["digitalProductPassportId"]).to eq(dpp_id)
    end

    it "resolves product identifiers to DPP identifiers" do
      create_dpp!

      post "/dpp/v1/dppsByProductIds", params: [product_id].to_json, headers: json
      expect(response).to have_http_status(:ok)
      body = JSON.parse(response.body)
      expect(body["statusCode"]).to eq("Success")
      expect(body["payload"]).to eq([dpp_id])
    end

    # EN 18222:2026 4.5 and Table 17: a set of product IDs in, a set of DPP IDs
    # out. Each passport carries one product identifier, so this is the union.
    it "returns the passports of every product in the set, not only those matching all" do
      create_dpp!
      other_product = product_id.sub("09520123456788", "09520123456795")
      post "/dpp/v1/dpps",
           params: dpp_document.merge("digitalProductPassportId" => "#{dpp_id}-2",
                                      "uniqueProductIdentifier" => other_product).to_json,
           headers: auth
      expect(response).to have_http_status(:created)

      post "/dpp/v1/dppsByProductIds", params: [product_id, other_product].to_json, headers: json

      expect(response).to have_http_status(:ok)
      expect(JSON.parse(response.body)["payload"]).to contain_exactly(dpp_id, "#{dpp_id}-2")
    end

    it "pages through the set without skipping a passport, even when asked for no page at all" do
      create_dpp!
      other_product = product_id.sub("09520123456788", "09520123456795")
      post "/dpp/v1/dpps",
           params: dpp_document.merge("digitalProductPassportId" => "#{dpp_id}-2",
                                      "uniqueProductIdentifier" => other_product).to_json,
           headers: auth

      seen = []
      cursor = nil
      3.times do
        query = { limit: 0, cursor: cursor }.compact.to_query
        post "/dpp/v1/dppsByProductIds?#{query}", params: [product_id, other_product].to_json, headers: json
        body = JSON.parse(response.body)
        seen.concat(body["payload"])
        cursor = body["nextCursor"]
        break if cursor.nil?
      end

      expect(seen).to contain_exactly(dpp_id, "#{dpp_id}-2")
    end

    it "applies an RFC 7396 merge patch to the DPP" do
      create_dpp!

      patch "/dpp/v1/dpps/#{enc_dpp}",
            params: { "facilityId" => "https://id.lumina.example/414/0952012345016" }.to_json,
            headers: patch_headers

      expect(response).to have_http_status(:ok)
      expect(JSON.parse(response.body)["facilityId"]).to end_with("0952012345016")
    end

    it "refuses a second active passport for the same product with 409" do
      create_dpp!

      post "/dpp/v1/dpps",
           params: dpp_document.merge("digitalProductPassportId" => "#{dpp_id}-2").to_json,
           headers: auth

      expect(response).to have_http_status(:conflict)
      body = JSON.parse(response.body)
      expect(body["statusCode"]).to eq("ClientResourceConflict")
      expect(body["message"].first["text"]).to include(dpp_id)
      expect(Dpp.where(product_id: product_id).count).to eq(1)
    end

    it "compares the host without regard to case, as DNS does" do
      create_dpp!

      shouted = product_id.sub("id.lumina.example", "ID.Lumina.Example")
      post "/dpp/v1/dpps",
           params: dpp_document.merge("digitalProductPassportId" => "#{dpp_id}-2",
                                      "uniqueProductIdentifier" => shouted).to_json,
           headers: auth

      expect(response).to have_http_status(:conflict)
    end

    it "accepts the same path under another host, which is another operator's product" do
      create_dpp!

      other_host = product_id.sub("id.lumina.example", "id.other-operator.example")
      post "/dpp/v1/dpps",
           params: dpp_document.merge("digitalProductPassportId" => "#{dpp_id}-2",
                                      "uniqueProductIdentifier" => other_host).to_json,
           headers: auth

      expect(response).to have_http_status(:created)
    end

    it "accepts a new passport once the previous one was deleted" do
      create_dpp!
      delete "/dpp/v1/dpps/#{enc_dpp}", headers: auth
      expect(response).to have_http_status(:no_content)

      post "/dpp/v1/dpps",
           params: dpp_document.merge("digitalProductPassportId" => "#{dpp_id}-2").to_json,
           headers: auth

      expect(response).to have_http_status(:created)
    end

    it "answers 409 when a concurrent create wins the race past the check" do
      rival = "#{dpp_id}-rival"
      # The rival row appears between the check and the insert, as it would
      # when two creates for the same product run at the same time.
      allow_any_instance_of(Dpp).to receive(:save!).and_wrap_original do |original, *args|
        Dpp.insert!({ dpp_id: rival, product_id: product_id, dpp_schema_version: "EN 18223:2026",
                      economic_operator_id: dpp_document["economicOperatorId"],
                      last_update: Time.current, product_key: "/01/09520123456788",
                      product_host: "id.lumina.example" })
        original.call(*args)
      end

      post "/dpp/v1/dpps", params: dpp_document.to_json, headers: auth

      expect(response).to have_http_status(:conflict)
      expect(JSON.parse(response.body)["message"].first["text"]).to include(rival)
      expect(Dpp.where(product_id: product_id).pluck(:dpp_id)).to eq([rival])
    end

    it "keeps a passport inside its availability period from being deleted" do
      post "/dpp/v1/dpps", params: dpp_document.to_json, headers: auth.merge("X-DPP-Retain-Until" => "2037-03-01")
      expect(response).to have_http_status(:created)
      expect(response.headers["X-DPP-Retain-Until"]).to eq("2037-03-01")
      expect(Dpp.find(dpp_id).retain_until).to eq(Date.new(2037, 3, 1))

      delete "/dpp/v1/dpps/#{enc_dpp}", headers: auth

      expect(response).to have_http_status(:forbidden)
      expect(JSON.parse(response.body)["message"].first["text"]).to include("2037-03-01")
      expect(Dpp.exists?(dpp_id)).to be(true)
    end

    it "holds the passport on the last day of the period, and lets it go after" do
      post "/dpp/v1/dpps", params: dpp_document.to_json,
                           headers: auth.merge("X-DPP-Retain-Until" => Date.current.iso8601)
      expect(response).to have_http_status(:created)

      dpp = Dpp.find(dpp_id)
      expect(dpp.retained?).to be(true)
      expect(dpp.retained?(Date.current.next_day)).to be(false)

      dpp.update_column(:retain_until, Date.current.prev_day)
      delete "/dpp/v1/dpps/#{enc_dpp}", headers: auth
      expect(response).to have_http_status(:no_content)
    end

    it "refuses a period that is not a date, and creates nothing" do
      post "/dpp/v1/dpps", params: dpp_document.to_json, headers: auth.merge("X-DPP-Retain-Until" => "next year")

      expect(response).to have_http_status(:bad_request)
      expect(JSON.parse(response.body)["message"].first["text"]).to include("X-DPP-Retain-Until")
      expect(Dpp.count).to eq(0)
    end

    it "refuses an operator identifier that follows none of the EN 18219 schemes, and creates nothing" do
      post "/dpp/v1/dpps", params: dpp_document.merge("economicOperatorId" => "Lumina GmbH").to_json, headers: auth

      expect(response).to have_http_status(:bad_request)
      expect(JSON.parse(response.body)["message"].first["text"]).to include("EN 18219")
      expect(Dpp.count).to eq(0)
    end

    it "accepts an operator identified by an ISO/IEC 6523 identifier instead of a DID" do
      post "/dpp/v1/dpps", params: dpp_document.merge("economicOperatorId" => "0199:5299000J2N45DDNE4Y28").to_json,
                           headers: auth

      expect(response).to have_http_status(:created)
      expect(JSON.parse(response.body)["economicOperatorId"]).to eq("0199:5299000J2N45DDNE4Y28")
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
      get "/dpp/v1/dpps/#{enc_dpp}/collections/EnergyPerformance?representation=full"
      expect(response).to have_http_status(:ok)
      expect(JSON.parse(response.body)["elements"].size).to eq(2)
    end

    it "reads a single data element by its absolute element path" do
      get "/dpp/v1/dpps/#{enc_dpp}/elements/EnergyPerformance/LuminousFlux?representation=full"

      expect(response).to have_http_status(:ok)
      body = JSON.parse(response.body)
      expect(body["value"]).to eq(806)
      expect(body["unitOfMeasure"]).to eq("lm")
    end

    # Regression: assign_path indexed the elements array with a String and
    # raised TypeError -> 500.
    it "patches a single data element inside a collection" do
      patch "#{efficiency_class_path}?representation=full", params: { "value" => "D" }.to_json,
                                                          headers: patch_headers

      expect(response).to have_http_status(:ok)
      expect(JSON.parse(response.body)["value"]).to eq("D")

      get efficiency_class_path
      expect(JSON.parse(response.body)).to eq("D")
    end

    it "returns 404 for an unknown element path" do
      get "/dpp/v1/dpps/#{enc_dpp}/elements/Nope/Nope"
      expect(response).to have_http_status(:not_found)
    end

    it "patches a data element collection" do
      patch "/dpp/v1/dpps/#{enc_dpp}/collections/EnergyPerformance?representation=full",
            params: { "dictionaryReference" => "https://dictionary.example/energyPerformance" }.to_json,
            headers: patch_headers

      expect(response).to have_http_status(:ok)
      expect(JSON.parse(response.body)["dictionaryReference"])
        .to eq("https://dictionary.example/energyPerformance")
    end
  end

  describe "Archiving (EN 18221:2026 4.2)" do
    before { create_dpp! }

    it "archives the previous state and serves it by date" do
      before_change = Time.now.utc

      patch efficiency_class_path, params: { "value" => "D" }.to_json, headers: patch_headers
      expect(response).to have_http_status(:ok)

      get "/dpp/v1/dppsByIdAndDate/#{enc_dpp}", params: { date: before_change.iso8601, representation: "full" }
      expect(response).to have_http_status(:ok)

      element = JSON.parse(response.body)["elements"]
                    .find { |c| c["elementId"] == "EnergyPerformance" }["elements"]
                    .find { |e| e["elementId"] == "EnergyEfficiencyClass" }
      expect(element["value"]).to eq("E") # the value *before* the patch
    end

    # Regression: dpp_versions was dependent: :destroy, so DeleteDPPById wiped
    # the history it had just written.
    it "keeps the archived history after DeleteDPPById" do
      deleted_at = Time.now.utc

      delete "/dpp/v1/dpps/#{enc_dpp}", headers: auth
      expect(response).to have_http_status(:no_content)

      get "/dpp/v1/dpps/#{enc_dpp}"
      expect(response).to have_http_status(:not_found)

      get "/dpp/v1/dppsByIdAndDate/#{enc_dpp}", params: { date: deleted_at.iso8601 }
      expect(response).to have_http_status(:ok)
      body = JSON.parse(response.body)
      expect(body["digitalProductPassportId"]).to eq(dpp_id)
      expect(body["dppStatus"]).to eq("Archived")
    end

    it "rejects an invalid date" do
      get "/dpp/v1/dppsByIdAndDate/#{enc_dpp}", params: { date: "gestern" }
      expect(response).to have_http_status(:bad_request)
      expect(JSON.parse(response.body)["statusCode"]).to eq("ClientErrorBadRequest")
    end
  end

  describe "Registry API (Clause 5)" do
    # No registry connection exists. A well-formed entry must therefore be
    # answered with a failure, never with a registration identifier: a client
    # would record the passport as registered.
    it "says that nothing was registered and invents no identifier" do
      post "/dpp/v1/registerDPP",
           params: { "dppRegistryEntry" => {
             "uniqueProductIdentifier" => product_id,
             "uniqueEconomicOperatorIdentifier" => "did:oyd:zQmPPwHJK1NHBz3BS89StWsfrH4pzkyqwJiK94zVj25wXUS"
           } }.to_json,
           headers: auth

      expect(response).to have_http_status(:bad_gateway)
      body = JSON.parse(response.body)
      expect(body["statusCode"]).to eq("ServerErrorBadGateway")
      expect(body).not_to have_key("registrationId")
      expect(body["message"].first["code"]).to eq("registryNotConnected")
    end

    # EN 18222:2026 7.1 Table 11 spells the operator uniqueEconomicOperatorIdentifier
    # where EN 18223 Table 1 has economicOperatorId. Both are accepted, so a client
    # that has the passport header at hand does not have to rename a field to
    # register it.
    it "also accepts the EN 18223 spelling of the operator" do
      post "/dpp/v1/registerDPP",
           params: { "dppRegistryEntry" => {
             "uniqueProductIdentifier" => product_id,
             "economicOperatorId" => "did:oyd:zQmPPwHJK1NHBz3BS89StWsfrH4pzkyqwJiK94zVj25wXUS"
           } }.to_json,
           headers: auth

      # Accepted as complete: the answer is the missing registry, not a 400.
      expect(response).to have_http_status(:bad_gateway)
    end

    it "requires the product identifier and the operator" do
      post "/dpp/v1/registerDPP",
           params: { "dppRegistryEntry" => { "uniqueProductIdentifier" => product_id } }.to_json,
           headers: auth
      expect(response).to have_http_status(:bad_request)
    end

    it "requires a token" do
      post "/dpp/v1/registerDPP",
           params: { "dppRegistryEntry" => { "uniqueProductIdentifier" => product_id } }.to_json,
           headers: json
      expect(response).to have_http_status(:unauthorized)
    end
  end
end
