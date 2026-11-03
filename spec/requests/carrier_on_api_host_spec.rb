# frozen_string_literal: true

require "rails_helper"

# An instance with one host only: DPP_CARRIER_HOSTS names the API host itself.
# The API, the start page and the other pages keep their paths; a path none of
# them takes is looked up as a product identifier.
RSpec.describe "Carrier path on the API host", type: :request do
  let(:api_host)   { "pace.example.org" }
  let(:path)       { "/01/09520123456788/21/TEST-0101" }
  let(:product_id) { "https://#{api_host}#{path}" }
  let(:token) { "Bearer #{JWT.encode({ sub: 'did:oyd:zQmPPwHJK1NHBz3BS89StWsfrH4pzkyqwJiK94zVj25wXUS' }, nil, 'none')}" }
  let(:auth)  { { "Content-Type" => "application/json", "Authorization" => token } }
  let(:as_json) { { "Accept" => "application/json" } }

  let(:document) do
    {
      "digitalProductPassportId" => "https://#{api_host}/passports/TEST-0101",
      "uniqueProductIdentifier" => product_id,
      "granularity" => "item",
      "dppSchemaVersion" => "EN 18223:2026",
      "dppStatus" => "Active",
      "economicOperatorId" => "did:oyd:zQmPPwHJK1NHBz3BS89StWsfrH4pzkyqwJiK94zVj25wXUS",
      "elements" => [
        { "elementId" => "ProductIdentification", "objectType" => "DataElementCollection",
          "elements" => [
            { "elementId" => "ModelIdentifier", "objectType" => "SingleValuedDataElement",
              "valueDataType" => "xsd:string", "value" => "LUM-1" }
          ] }
      ]
    }
  end

  around do |example|
    previous = ENV.fetch("DPP_SERVICE_ENDPOINT_BASE", nil)
    ENV["DPP_SERVICE_ENDPOINT_BASE"] = "https://#{api_host}"
    example.run
  ensure
    previous.nil? ? ENV.delete("DPP_SERVICE_ENDPOINT_BASE") : ENV["DPP_SERVICE_ENDPOINT_BASE"] = previous
  end

  before do
    allow(CarrierHosts).to receive(:list).and_return([api_host])
    host! api_host
    post "/dpp/v1/dpps", params: document.to_json, headers: auth
    expect(response).to have_http_status(:created)
  end

  def json = JSON.parse(response.body)

  it "says on creating that this service answers the identifier" do
    expect(response.headers["X-DPP-Carrier"]).to eq("served")
  end

  it "answers the identifier with the passport" do
    get path, headers: as_json

    expect(response).to have_http_status(:ok)
    expect(json["uniqueProductIdentifier"]).to eq(product_id)
    expect(response.headers["Vary"]).to include("Accept")
  end

  it "shows a browser the passport page" do
    get path, headers: { "Accept" => "text/html,application/xhtml+xml,*/*;q=0.8" }

    expect(response).to have_http_status(:ok)
    expect(response.media_type).to eq("text/html")
  end

  it "keeps the API, the start page and the other pages where they are" do
    get "/dpp/v1/dppsByProductId/#{CGI.escape(product_id)}", headers: as_json
    expect(response).to have_http_status(:ok)

    get "/"
    expect(response).to have_http_status(:ok)
    expect(response.body).to include("<title>DPP Service · OwnYourData</title>")

    get "/privacy"
    expect(response).to have_http_status(:ok)

    get "/up"
    expect(response).to have_http_status(:ok)
    expect(JSON.parse(response.body)).to eq("status" => "ok")

    get "/version"
    expect(response).to have_http_status(:ok)
  end

  it "answers an identifier nobody has with 404" do
    get "/01/09520123456788/21/OTHER", headers: as_json

    expect(response).to have_http_status(:not_found)
    expect(json["statusCode"]).to eq("ClientErrorResourceNotFound")
  end

  it "answers an API address that does not exist with 404, without pointing elsewhere" do
    get "/dpp/v1/nothing-here", headers: as_json

    expect(response).to have_http_status(:not_found)
    expect(json.dig("message", 0, "text")).not_to include("the API is at")
  end

  it "leaves another carrier host as it was" do
    allow(CarrierHosts).to receive(:list).and_return([api_host, "id.example.org"])
    host! "id.example.org"

    get "/up", headers: as_json
    expect(response).to have_http_status(:not_found)
    expect(json.dig("message", 0, "text")).to include("the API is at https://#{api_host}")
  end

  it "does not answer identifiers on the API host unless it is listed" do
    allow(CarrierHosts).to receive(:list).and_return([])
    get path, headers: as_json

    expect(response).to have_http_status(:not_found)
  end
end
