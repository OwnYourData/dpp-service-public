# frozen_string_literal: true

require "rails_helper"

# X-DPP-Warning: a write that leaves a related resource without its media type
# is stored, and the answer says so (WriteWarnings).
RSpec.describe "Write warnings", type: :request do
  let(:token) { "Bearer #{JWT.encode({ sub: 'did:oyd:zQmPPwHJK1NHBz3BS89StWsfrH4pzkyqwJiK94zVj25wXUS' }, nil, 'none')}" }
  let(:auth)  { { "Content-Type" => "application/json", "Authorization" => token } }
  let(:patch_auth) { auth.merge("Content-Type" => "application/merge-patch+json") }

  def document(resources)
    {
      "digitalProductPassportId" => "https://dpp.example.org/passports/WARN-0001",
      "uniqueProductIdentifier" => "https://id.example.org/01/09520123456788/21/WARN-0001",
      "granularity" => "item",
      "dppSchemaVersion" => "EN 18223:2026",
      "dppStatus" => "Active",
      "economicOperatorId" => "did:oyd:zQmPPwHJK1NHBz3BS89StWsfrH4pzkyqwJiK94zVj25wXUS",
      "elements" => [
        { "elementId" => "ProductIdentification", "objectType" => "DataElementCollection",
          "elements" => [{ "elementId" => "ModelIdentifier", "objectType" => "SingleValuedDataElement",
                           "valueDataType" => "xsd:string", "value" => "LUM-1" }] }
      ] + resources
    }
  end

  let(:untyped) { { "elementId" => "DeclarationOfConformity", "objectType" => "RelatedResource", "url" => "https://example.org/doc.pdf" } }
  let(:typed)   { untyped.merge("contentType" => "application/pdf") }

  def create(resources)
    post "/dpp/v1/dpps", params: document(resources).to_json, headers: auth
    expect(response).to have_http_status(:created)
    JSON.parse(response.body)["digitalProductPassportId"]
  end

  it "stores a passport with an untyped related resource and warns about it" do
    create([untyped])

    expect(response.headers["X-DPP-Warning"])
      .to eq('missingContentType;element="$.DeclarationOfConformity"')
  end

  it "sends no warning when every related resource has its type" do
    create([typed])

    expect(response.headers).not_to have_key("X-DPP-Warning")
  end

  it "warns after an update that removes the type, and stops once it is back" do
    id = create([typed])

    patch "/dpp/v1/dpps/#{CGI.escape(id)}/elements/#{CGI.escape('$.DeclarationOfConformity')}",
          params: { "contentType" => nil }.to_json, headers: patch_auth
    expect(response).to have_http_status(:ok)
    expect(response.headers["X-DPP-Warning"]).to include('element="$.DeclarationOfConformity"')

    patch "/dpp/v1/dpps/#{CGI.escape(id)}/elements/#{CGI.escape('$.DeclarationOfConformity')}",
          params: { "contentType" => "application/pdf" }.to_json, headers: patch_auth
    expect(response).to have_http_status(:ok)
    expect(response.headers).not_to have_key("X-DPP-Warning")
  end

  it "lists at most twenty and says how many more there are" do
    many = (1..23).map { |i| untyped.merge("elementId" => "Doc#{i}") }
    create(many)

    items = response.headers["X-DPP-Warning"].split(", ")
    expect(items.size).to eq(20)
    expect(items.last).to end_with(";more=3")
  end

  it "is not sent on reads" do
    id = create([untyped])

    get "/dpp/v1/dpps/#{CGI.escape(id)}", headers: { "Accept" => "application/json" }
    expect(response).to have_http_status(:ok)
    expect(response.headers).not_to have_key("X-DPP-Warning")
  end
end
