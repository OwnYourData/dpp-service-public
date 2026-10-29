# frozen_string_literal: true

require "rails_helper"

# The carrier path: the product identifier a data carrier bears, answered on
# a carrier host (DPP_CARRIER_HOSTS) for the passports this service keeps.
RSpec.describe "Carrier path", type: :request do
  let(:carrier_host) { "id.example.org" }
  let(:path)         { "/01/09520123456788/21/TEST-0001" }
  let(:product_id)   { "https://#{carrier_host}#{path}" }
  let(:token) { "Bearer #{JWT.encode({ sub: 'did:oyd:zQmPPwHJK1NHBz3BS89StWsfrH4pzkyqwJiK94zVj25wXUS' }, nil, 'none')}" }
  let(:auth)  { { "Content-Type" => "application/json", "Authorization" => token } }

  let(:document) do
    {
      "digitalProductPassportId" => "https://#{carrier_host}/passports/TEST-0001",
      "uniqueProductIdentifier" => product_id,
      "granularity" => "item",
      "dppSchemaVersion" => "EN 18223:2026",
      "dppStatus" => "Active",
      "economicOperatorId" => "did:oyd:zQmPPwHJK1NHBz3BS89StWsfrH4pzkyqwJiK94zVj25wXUS",
      "elements" => [
        { "elementId" => "ProductIdentification", "objectType" => "DataElementCollection",
          "elements" => [
            { "elementId" => "ModelIdentifier", "objectType" => "SingleValuedDataElement",
              "valueDataType" => "xsd:string", "value" => "<b>LUM</b> & co" },
            { "elementId" => "OnModePower", "objectType" => "SingleValuedDataElement",
              "valueDataType" => "xsd:decimal", "unitOfMeasure" => "W", "value" => 8.5 }
          ] },
        { "elementId" => "DeclarationOfConformity", "objectType" => "RelatedResource",
          "contentType" => "application/pdf", "url" => "https://example.org/doc.pdf" },
        { "elementId" => "Elsewhere", "objectType" => "RelatedResource",
          "contentType" => "text/html", "url" => "javascript:alert(1)" }
      ]
    }
  end

  before do
    allow(CarrierHosts).to receive(:list).and_return([carrier_host])
    post "/dpp/v1/dpps", params: document.to_json, headers: auth
    expect(response).to have_http_status(:created)
    host! carrier_host
  end

  def json = JSON.parse(response.body)

  # Rails sends a browser's Accept by default, text/html included; a client of
  # the data says what it wants.
  let(:as_json) { { "Accept" => "application/json" } }

  describe "JSON" do
    it "answers the identifier with the passport whose uniqueProductIdentifier it is, in the full form" do
      get path, headers: as_json

      expect(response).to have_http_status(:ok)
      expect(response.media_type).to eq("application/json")
      expect(json["uniqueProductIdentifier"]).to eq(product_id)
      expect(json["elements"].first["objectType"]).to eq("DataElementCollection")
      expect(response.headers["Vary"]).to include("Accept")
    end

    it "stays JSON for */*, for no Accept and when HTML is weighted lower" do
      ["*/*", "", "application/json, text/html;q=0.1", "application/json"].each do |accept|
        get path, headers: { "Accept" => accept }

        expect(response.media_type).to eq("application/json"), accept.inspect
      end
    end

    it "gives the compressed form when asked, and refuses another representation with 400" do
      get path, params: { representation: "compressed" }, headers: as_json
      expect(json["ProductIdentification"]).to eq("ModelIdentifier" => "<b>LUM</b> & co", "OnModePower" => 8.5)

      get path, params: { representation: "bogus" }, headers: as_json
      expect(response).to have_http_status(:bad_request)
    end

    it "reports the states the read paths report" do
      get path, headers: as_json

      expect(response.headers["X-DPP-Signature-State"]).to eq("none")
    end

    it "answers HEAD" do
      head path

      expect(response).to have_http_status(:ok)
      expect(response.body).to be_empty
    end

    it "compares the host without regard to case, as DNS does" do
      host! carrier_host.upcase
      get path

      expect(response).to have_http_status(:ok)
    end

    it "sets no cookie" do
      get path, headers: as_json
      expect(response.headers["Set-Cookie"]).to be_nil

      get path, headers: { "Accept" => "text/html" }
      expect(response.headers["Set-Cookie"]).to be_nil
    end
  end

  describe "HTML" do
    it "is what a browser gets, escaped, self-contained and without a script" do
      get path, headers: { "Accept" => "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8" }

      expect(response).to have_http_status(:ok)
      expect(response.media_type).to eq("text/html")
      expect(response.headers["Vary"]).to include("Accept")
      expect(response.headers["Content-Security-Policy"]).to include("default-src 'none'")
      expect(response.body).to include("&lt;b&gt;LUM&lt;/b&gt; &amp; co")
      expect(response.body).to include("8.5 W")
      expect(response.body).to include(%(href="https://example.org/doc.pdf"))
      expect(response.body).to include("application/pdf")
      expect(response.body).not_to include("<script")
      expect(response.body).not_to include(%(href="javascript:))
      expect(response.body).to include(%(<link rel="alternate" type="application/json"))
    end

    it "is built from the full form whatever representation is asked for" do
      get path, params: { representation: "compressed" }, headers: { "Accept" => "text/html" }

      expect(response.body).to include("8.5 W")
    end

    it "gives way to the signature when that is weighted as high" do
      get path, headers: { "Accept" => "text/html, application/jose" }

      expect(response.media_type).not_to eq("text/html")
    end
  end

  describe "what is not a passport" do
    it "answers an identifier nobody has with 404" do
      get "/01/09520123456788/21/OTHER", headers: as_json

      expect(response).to have_http_status(:not_found)
      expect(json["statusCode"]).to eq("ClientErrorResourceNotFound")
      expect(response.headers["Vary"]).to include("Accept")
    end

    it "shows a browser a short page for an identifier nobody has, still with 404" do
      get "/01/09520123456788/21/%3COTHER%3E", headers: { "Accept" => "text/html,application/xhtml+xml,*/*;q=0.8" }

      expect(response).to have_http_status(:not_found)
      expect(response.media_type).to eq("text/html")
      expect(response.headers["Vary"]).to include("Accept")
      expect(response.headers["Content-Security-Policy"]).to include("default-src 'none'")
      expect(response.body).to include("No passport found")
      expect(response.body).not_to include("<OTHER>")
      expect(response.body).not_to include("<script")
      expect(response.cookies).to be_empty
    end

    it "keeps JSON for an unknown identifier when HTML has no lead" do
      ["*/*", "", "application/json, text/html"].each do |accept|
        get "/01/09520123456788/21/OTHER", headers: { "Accept" => accept }

        expect(response).to have_http_status(:not_found), accept
        expect(response.media_type).to eq("application/json"), accept
      end
    end

    it "answers HEAD for an unknown identifier with 404 and no body" do
      head "/01/09520123456788/21/OTHER", headers: { "Accept" => "text/html" }

      expect(response).to have_http_status(:not_found)
      expect(response.body).to be_empty
    end

    it "does not answer for a passport whose identifier names another host" do
      allow(CarrierHosts).to receive(:list).and_return([carrier_host, "other.example.org"])
      host! "other.example.org"
      get path

      expect(response).to have_http_status(:not_found)
    end

    it "says where the API is when asked for one of its addresses" do
      ["/dpp/v1/dpps", "/api-docs", "/.well-known/dpp-service", "/up", "/version"].each do |api_path|
        get api_path, headers: as_json

        expect(response).to have_http_status(:not_found), api_path
        expect(json.dig("message", 0, "text")).to include("the API is at"), api_path
      end
    end

    it "refuses anything but GET and HEAD" do
      post path, params: "{}", headers: { "Content-Type" => "application/json" }

      expect(response).to have_http_status(:method_not_allowed)
      expect(response.headers["Allow"]).to eq("GET, HEAD")
    end

    it "shows a short page at its root" do
      get "/"

      expect(response).to have_http_status(:ok)
      expect(response.media_type).to eq("text/html")
      expect(response.body).to include("Product identifiers")
    end
  end

  describe "the API host" do
    it "keeps serving the API and does not answer identifiers" do
      host! "www.example.com"

      get "/dpp/v1/dppsByProductId/#{CGI.escape(product_id)}", headers: as_json
      expect(response).to have_http_status(:ok)

      head "/dpp/v1/dppsByProductId/#{CGI.escape(product_id)}"
      expect(response).to have_http_status(:ok)

      get path
      expect(response).to have_http_status(:not_found)
    end

    it "leaves a deployment without carrier hosts as it was" do
      allow(CarrierHosts).to receive(:list).and_return([])
      get path, headers: as_json

      expect(response).to have_http_status(:not_found)
    end
  end

  describe "creating a passport" do
    it "says whether a carrier host of this service answers its identifier" do
      host! "www.example.com"
      post "/dpp/v1/dpps", params: document.merge(
        "digitalProductPassportId" => "https://#{carrier_host}/passports/TEST-0002",
        "uniqueProductIdentifier" => "https://#{carrier_host}/01/09520123456788/21/TEST-0002"
      ).to_json, headers: auth
      expect(response.headers["X-DPP-Carrier"]).to eq("served")

      post "/dpp/v1/dpps", params: document.merge(
        "digitalProductPassportId" => "https://p.lumina.example/passports/TEST-0003",
        "uniqueProductIdentifier" => "https://p.lumina.example/01/09520123456788/21/TEST-0003"
      ).to_json, headers: auth
      expect(response.headers["X-DPP-Carrier"]).to eq("unserved")
    end

    it "says nothing while no carrier host is configured" do
      allow(CarrierHosts).to receive(:list).and_return([])
      host! "www.example.com"
      post "/dpp/v1/dpps", params: document.merge(
        "digitalProductPassportId" => "https://#{carrier_host}/passports/TEST-0004",
        "uniqueProductIdentifier" => "https://#{carrier_host}/01/09520123456788/21/TEST-0004"
      ).to_json, headers: auth

      expect(response).to have_http_status(:created)
      expect(response.headers).not_to have_key("X-DPP-Carrier")
    end
  end
end
