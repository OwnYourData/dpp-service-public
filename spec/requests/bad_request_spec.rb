# frozen_string_literal: true

require "rails_helper"

# EN 18222:2026 7.2, Table 15: a bad or malformed request is answered with 400
# and a Result object. A request that is well-formed JSON but has the wrong shape
# is as bad as one that does not parse, and neither may surface as a server
# error. A server error that does happen still carries a Result object.
RSpec.describe "Bad requests", type: :request do
  let(:token) { "Bearer #{JWT.encode({ sub: 'did:oyd:zQmPPwHJK1NHBz3BS89StWsfrH4pzkyqwJiK94zVj25wXUS', scope: 'dpp:write' }, nil, 'none')}" }
  let(:json)  { { "Content-Type" => "application/json" } }
  let(:auth)  { json.merge("Authorization" => token) }

  let(:dpp_id)     { "https://dpp.lumina.example/01/09520123456788/8546" }
  let(:product_id) { "https://id.lumina.example/01/09520123456788" }
  let(:enc_dpp)    { CGI.escape(dpp_id) }

  let(:dpp_document) do
    {
      "digitalProductPassportId" => dpp_id,
      "uniqueProductIdentifier" => product_id,
      "granularity" => "model",
      "dppSchemaVersion" => "EN 18223:2026",
      "dppStatus" => "Active",
      "economicOperatorId" => "did:oyd:zQmPPwHJK1NHBz3BS89StWsfrH4pzkyqwJiK94zVj25wXUS",
      "elements" => [
        { "elementId" => "ProductIdentification", "objectType" => "DataElementCollection",
          "elements" => [
            { "elementId" => "ModelIdentifier", "objectType" => "SingleValuedDataElement",
              "value" => "LUM-A60-827-806", "valueDataType" => "xsd:string" }
          ] }
      ]
    }
  end

  def expect_bad_request
    expect(response).to have_http_status(:bad_request)
    body = JSON.parse(response.body)
    expect(body["statusCode"]).to eq("ClientErrorBadRequest")
    expect(body["message"].first["text"]).to be_present
  end

  describe "ReadDPPIdsByProductIds (EN 18222:2026 4.5, Table 4)" do
    ['{"productId":42}', '{"productId":"https://id.lumina.example/01/09520123456788"}',
     '{"productId":[]}', '{"productId":[42]}', '{"productIds":["https://id.lumina.example/01/09520123456788"]}',
     '{"productId":["https://id.lumina.example/01/09520123456788"],"limit":5}',
     "42", '"https://id.lumina.example/01/09520123456788"', "[42]", '[{"a":1}]',
     "[null]", '[["a"]]', '[""]', "[]", "null"].each do |body|
      it "answers #{body} with 400" do
        post "/dpp/v1/dppsByProductIds", params: body, headers: json
        expect_bad_request
      end
    end

    it "still answers a body that does not parse with 400" do
      post "/dpp/v1/dppsByProductIds", params: "{not json", headers: json
      expect_bad_request
    end

    it "still answers an array of identifiers" do
      post "/dpp/v1/dppsByProductIds", params: [product_id].to_json, headers: json
      expect(response).to have_http_status(:ok)
      expect(JSON.parse(response.body)["payload"]).to eq([])
    end

    it "takes the same set as the productId member of an object, the name Table 4 gives it" do
      post "/dpp/v1/dpps", params: dpp_document.to_json, headers: auth
      expect(response).to have_http_status(:created)

      post "/dpp/v1/dppsByProductIds", params: { productId: [product_id] }.to_json, headers: json
      expect(response).to have_http_status(:ok)
      expect(JSON.parse(response.body)["payload"]).to eq([dpp_id])
    end
  end

  describe "CreateDPP and UpdateDPPById" do
    it "answers a passport that is not a JSON object with 400" do
      post "/dpp/v1/dpps", params: [dpp_document].to_json, headers: auth
      expect_bad_request
    end

    it "answers a merge patch that is not a JSON object with 400" do
      post "/dpp/v1/dpps", params: dpp_document.to_json, headers: auth
      expect(response).to have_http_status(:created)

      patch "/dpp/v1/dpps/#{enc_dpp}", params: "[1]",
                                       headers: auth.merge("Content-Type" => "application/merge-patch+json")
      expect_bad_request
    end
  end

  describe "an unexpected error" do
    it "is answered with 500 and a Result object, without the internals" do
      allow(Dpp).to receive(:where).and_raise(RuntimeError, "secret internals")

      post "/dpp/v1/dppsByProductIds", params: [product_id].to_json, headers: json

      expect(response).to have_http_status(:internal_server_error)
      body = JSON.parse(response.body)
      expect(body["statusCode"]).to eq("ServerInternalError")
      expect(response.body).not_to include("secret internals")
    end
  end

  describe "ReadDataElement (EN 18222:2026 6.2, 8.1: elementIdPath is RFC 9535 JSONPath)" do
    before do
      post "/dpp/v1/dpps", params: dpp_document.to_json, headers: auth
      expect(response).to have_http_status(:created)
    end

    def element(path)
      get "/dpp/v1/dpps/#{enc_dpp}/elements/#{path}"
    end

    it "reads an element by a percent-encoded JSONPath" do
      element("#{ERB::Util.url_encode('$.ProductIdentification.ModelIdentifier')}?representation=full")

      expect(response).to have_http_status(:ok)
      expect(JSON.parse(response.body)).to include("elementId" => "ModelIdentifier", "value" => "LUM-A60-827-806")
    end

    it "reads an element by a bracketed JSONPath" do
      element(ERB::Util.url_encode("$['ProductIdentification']['ModelIdentifier']"))
      expect(response).to have_http_status(:ok)
    end

    it "keeps an encoded '/' inside a name as part of the name" do
      element(ERB::Util.url_encode("$['ProductIdentification/ModelIdentifier']"))
      expect(response).to have_http_status(:not_found)
    end

    it "reads the same element by its path of element identifiers" do
      element("ProductIdentification/ModelIdentifier")
      expect(response).to have_http_status(:ok)
    end

    it "answers an expression that is not JSONPath with 400" do
      element("%24%5B")
      expect_bad_request
    end

    it "answers a JSONPath that can select more than one element with 400" do
      element(ERB::Util.url_encode("$..ModelIdentifier"))
      expect_bad_request
    end

    it "answers a well-formed path that leads nowhere with 404" do
      element(ERB::Util.url_encode("$.ProductIdentification.Nope"))
      expect(response).to have_http_status(:not_found)
    end

    it "updates an element addressed by JSONPath" do
      patch "/dpp/v1/dpps/#{enc_dpp}/elements/#{ERB::Util.url_encode('$.ProductIdentification.ModelIdentifier')}" \
            "?representation=full",
            params: { "value" => "LUM-A60-827-810" }.to_json,
            headers: auth.merge("Content-Type" => "application/merge-patch+json")

      expect(response).to have_http_status(:ok)
      expect(JSON.parse(response.body)["value"]).to eq("LUM-A60-827-810")
    end
  end
end
