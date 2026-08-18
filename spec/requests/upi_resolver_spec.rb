# frozen_string_literal: true

require "rails_helper"

# Short-link UPI for the EU DPP Registry: each DPP gets a short id and a
# resolvable https URL (<= 50 chars, direct 200, no auth).
RSpec.describe "UPI short-link resolver", type: :request do
  let(:token) { "Bearer #{JWT.encode({ sub: 'did:oyd:zQmPPwHJK1NHBz3BS89StWsfrH4pzkyqwJiK94zVj25wXUS', scope: 'dpp:write' }, nil, 'none')}" }
  let(:auth)  { { "Content-Type" => "application/json", "Authorization" => token } }

  let(:dpp_document) do
    {
      "DigitalProductPassportID" => "https://dpp-service.ownyourdata.eu/01/09520123456788/0001",
      "ProductID" => "https://id.lumina.example/01/09520123456788",
      "Granularity" => "model",
      "DPPSchemaVersion" => "prEN 18223:2025",
      "EconomicOperatorID" => "did:oyd:zQmPPwHJK1NHBz3BS89StWsfrH4pzkyqwJiK94zVj25wXUS"
    }
  end

  def create_dpp!
    post "/dpp/v1/dpps", params: dpp_document.to_json, headers: auth
    expect(response).to have_http_status(:created)
    JSON.parse(response.body)
  end

  it "assigns a short_id and exposes a UPI in the document" do
    body = create_dpp!
    expect(body["UPI"]).to match(%r{\Ahttps://r\.oydapp\.eu/p/[A-Za-z0-9]{12}\z})
  end

  it "keeps the UPI within the Registry's 50-character limit" do
    body = create_dpp!
    expect(body["UPI"].length).to be <= 50
  end

  it "resolves the UPI short link with a direct 200 (no redirect, no auth)" do
    body = create_dpp!
    short = body["UPI"].split("/").last

    get "/p/#{short}"
    expect(response).to have_http_status(:ok)
    expect(JSON.parse(response.body)["DigitalProductPassportID"]).to eq(dpp_document["DigitalProductPassportID"])
  end

  it "returns 404 for an unknown short id" do
    get "/p/doesnotexist1"
    expect(response).to have_http_status(:not_found)
  end

  it "gives each DPP a distinct short id" do
    a = create_dpp!
    dpp_document["DigitalProductPassportID"] = "https://dpp-service.ownyourdata.eu/01/09520123456788/0002"
    b = create_dpp!
    expect(a["UPI"]).not_to eq(b["UPI"])
  end
end
