# frozen_string_literal: true

require "rails_helper"
require_relative "../support/reading_with_access"

# A fine-granular read of a path the reader may not read (docs/AccessClasses.md
# §8, EN 18222:2026 Table 15): without a bearer token an element path that the
# access policy does not make public is refused with 401, with a valid token
# whose access rights do not reach it with 403 -- whether or not the element
# exists, so the answer tells nothing about what a passport holds. A path the
# reader may read that leads nowhere, and an unknown passport, stay 404. The
# reads of a whole passport keep giving the public part.
RSpec.describe "Reading a data element the reader may not read", type: :request do
  include_context "reading with access rights"

  def element(path, as: nil, id: enc)
    get "/dpp/v1/dpps/#{id}/elements/#{CGI.escape(path)}", headers: as ? { "Authorization" => bearer(as) } : {}
  end

  def collection(name, as: nil)
    get "/dpp/v1/dpps/#{enc}/collections/#{CGI.escape(name)}", headers: as ? { "Authorization" => bearer(as) } : {}
  end

  def message = response.parsed_body["message"].first["text"]

  # Drops BrandName's neighbour OnModePower from the passport, so the policy
  # names an element the passport no longer has.
  def drop_on_mode_power
    patch "/dpp/v1/dpps/#{enc}", params: { "elements" => document["elements"].first(2) }.to_json,
                                 headers: json_headers(owner, "Content-Type" => "application/merge-patch+json")
    expect(response).to have_http_status(:ok)
  end

  shared_examples "a passport with an access policy" do
    it "refuses a controlled element with 401, by path of element identifiers and by JSONPath" do
      %w[SerialNumber $.SerialNumber OnModePower $['OnModePower']].each do |path|
        element(path)

        expect(response).to have_http_status(:unauthorized), path
        expect(response.parsed_body["statusCode"]).to eq("ClientNotAuthorized")
      end
    end

    it "answers a controlled path the passport does not have exactly like one it has" do
      element("OnModePower")
      present = [response.status, message]
      drop_on_mode_power

      element("OnModePower")

      expect([response.status, message]).to eq(present)
    end

    it "keeps 200 for a public element and 404 for a public path that leads nowhere" do
      element("BrandName")
      expect(response).to have_http_status(:ok)

      element("$.WarrantyPeriod")
      expect(response).to have_http_status(:not_found)
    end

    it "names the bearer scheme on the 401, and the error on one for a token that does not hold" do
      element("SerialNumber")
      expect(response.headers["WWW-Authenticate"]).to eq("Bearer")

      get "/dpp/v1/dpps/#{enc}/elements/BrandName", headers: { "Authorization" => "Bearer garbage" }
      expect(response).to have_http_status(:unauthorized)
      expect(response.headers["WWW-Authenticate"]).to eq('Bearer error="invalid_token"')
    end

    it "answers a withheld path the passport does not have exactly like one it has, with a token too" do
      element("OnModePower", as: li_reader)
      present = [response.status, message]
      drop_on_mode_power

      element("OnModePower", as: li_reader)

      expect([response.status, message]).to eq(present)
      expect(response.parsed_body["statusCode"]).to eq("ClientForbidden")
      expect(response.headers["WWW-Authenticate"]).to be_nil
      expect(response.headers["Cache-Control"]).to include("no-store")
    end

    it "keeps 404 for a path the reader may read that leads nowhere, the owner's included" do
      drop_on_mode_power

      element("OnModePower", as: au_reader)
      expect(response).to have_http_status(:not_found)

      element("OnModePower", as: owner)
      expect(response).to have_http_status(:not_found)

      element("$.WarrantyPeriod", as: nobody)
      expect(response).to have_http_status(:not_found)
    end

    it "keeps the public part with 200 on the reads of the whole passport" do
      passport_paths.each do |path|
        read(path, as: nobody)

        expect(response).to have_http_status(:ok)
        expect(element_ids(response.parsed_body)).to eq(%w[BrandName])
      end
    end

    it "keeps 404 for an unknown passport" do
      element("SerialNumber", id: CGI.escape("did:oyd:zQmUnknownPassport"))

      expect(response).to have_http_status(:not_found)
    end

    it "refuses a reader whose token does not reach the path with 403, and lets one through that does" do
      element("SerialNumber", as: nobody)
      expect(response).to have_http_status(:forbidden)

      element("SerialNumber", as: li_reader)
      expect(response).to have_http_status(:ok)

      element("OnModePower", as: li_reader)
      expect(response).to have_http_status(:forbidden)

      element("OnModePower", as: au_reader)
      expect(response).to have_http_status(:ok)
    end

    it "answers as before while tokens are not verified" do
      allow(DidTokenVerifier).to receive(:enabled?).and_return(false)

      element("SerialNumber")

      expect(response).to have_http_status(:not_found)
    end
  end

  describe "a passport this service holds" do
    before do
      create_locally
      grant_roles!
    end

    it_behaves_like "a passport with an access policy"
  end

  describe "a passport at a custodian that holds controlled cards" do
    before do
      create_at_pod
      grant_roles!
    end

    it_behaves_like "a passport with an access policy"
  end

  describe "a passport without an access policy" do
    before do
      register_policy
      post "/dpp/v1/dpps", params: document.to_json, headers: json_headers(owner)
      expect(response).to have_http_status(:created)
    end

    it "keeps 404 for a path that leads nowhere" do
      element("$.WarrantyPeriod")

      expect(response).to have_http_status(:not_found)
    end
  end

  describe "collections and a policy without a default" do
    let(:policy_doc) do
      { "id" => "https://dpp.example.org/access-policies/collections/1",
        "scheme" => AccessClass::SCHEME,
        "rules" => [
          { "path" => "ProductIdentification", "accessClass" => "public" },
          { "path" => "ProductIdentification/SerialNumber", "accessClass" => "legitimateInterest" },
          { "path" => "Warranty", "accessClass" => "public" },
          { "path" => "Warranty/Terms", "accessClass" => "authority" }
        ] }
    end

    def document(**)
      { "digitalProductPassportId" => dpp_id,
        "uniqueProductIdentifier" => product_id,
        "granularity" => "item",
        "dppSchemaVersion" => "EN 18223:2026",
        "dppStatus" => "Active",
        "economicOperatorId" => owner,
        "elements" => [
          { "elementId" => "ProductIdentification", "objectType" => "DataElementCollection",
            "elements" => [single("BrandName", "Lumina"), single("SerialNumber", "SN-0921")] }
        ] }
    end

    before { create_locally }

    it "gives the public part of a collection that has one" do
      collection("ProductIdentification")

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("Lumina")
      expect(response.body).not_to include("SN-0921")
    end

    it "refuses a collection that may hold controlled elements, although the passport has none of it" do
      collection("Warranty")

      expect(response).to have_http_status(:unauthorized)
    end

    it "refuses a controlled element below a public collection" do
      element("$.ProductIdentification.SerialNumber")

      expect(response).to have_http_status(:unauthorized)
    end

    it "refuses a path no rule reaches, which takes the most restrictive class" do
      element("$.Nope")
      expect(response).to have_http_status(:unauthorized)

      collection("Nope")
      expect(response).to have_http_status(:unauthorized)
    end

    it "keeps 404 for a header attribute, which is always public" do
      element("economicOperatorId")

      expect(response).to have_http_status(:not_found)
    end

    it "judges a reader with a token by the classes it holds, the rules below the path included" do
      grant_roles!

      collection("Warranty", as: li_reader)
      expect(response).to have_http_status(:forbidden)

      collection("Warranty", as: au_reader)
      expect(response).to have_http_status(:not_found)

      element("$.Nope", as: li_reader)
      expect(response).to have_http_status(:forbidden)

      element("$.ProductIdentification.Nope", as: nobody)
      expect(response).to have_http_status(:not_found)
    end
  end
end
