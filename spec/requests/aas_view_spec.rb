# frozen_string_literal: true

require "rails_helper"
require_relative "../support/reading_with_access"

# The AAS view of a passport (docs/AAS.md, AasView): read like ReadDPPById,
# derived from what that read hands out, named by the read paths.
RSpec.describe "AAS view", type: :request do
  # The data elements of PassportElements, without the digest of the
  # controlled part, which the public part names (PassportSplit).
  def property_ids(view)
    view["submodels"].find { |s| s["idShort"] == "PassportElements" }
                     .fetch("submodelElements", []).map { |e| e["idShort"] } - [PassportSplit::DIGEST_ELEMENT]
  end

  def shell(view) = view["assetAdministrationShells"].first
  def extension(view, name) = shell(view)["extensions"].find { |e| e["name"] == name }&.fetch("value")

  describe "with access rights" do
    include_context "reading with access rights"

    expected = {
      nil => %w[BrandName], "nobody" => %w[BrandName], "li" => %w[BrandName SerialNumber],
      "au" => %w[BrandName SerialNumber OnModePower], "owner" => %w[BrandName SerialNumber OnModePower]
    }.freeze

    def aas_paths
      ["/dpp/v1/dpps/#{enc}/aas", "/dpp/v1/dppsByProductId/#{CGI.escape(product_id)}/aas"]
    end

    describe "a passport at a custodian" do
      before do
        create_at_pod
        grant_roles!
      end

      expected.each do |role, attributes|
        it "gives #{role || 'a reader without a token'} exactly #{attributes.join(', ')}, as the read paths do" do
          aas_paths.each do |path|
            read(path, as: who(role))

            expect(response).to have_http_status(:ok)
            expect(response.media_type).to eq("application/json")
            expect(property_ids(response.parsed_body)).to eq(attributes)
            expect(response.headers["Vary"]).to include("Authorization", "Accept")
          end
        end
      end

      it "keeps the digest the public part names, and never hands out the salt" do
        read(aas_paths.first, as: au_reader)

        elements = response.parsed_body["submodels"].find { |s| s["idShort"] == "PassportElements" }["submodelElements"]
        digest = elements.find { |e| e["idShort"] == PassportSplit::DIGEST_ELEMENT }
        expect(digest["value"]).to eq(PassportSplit.named_digest(pod.public_payload(dpp_id)))
        expect(response.body).not_to include(PassportSplit::SALT_ELEMENT)
      end

      it "says which classes it applied and keeps the answer from every cache, like the read paths" do
        read(aas_paths.first, as: li_reader)
        expect(response.headers["X-DPP-Access-Roles"]).to eq("legitimateInterest")
        expect(response.headers["Cache-Control"]).to eq("private, no-store")

        read(aas_paths.first)
        expect(response.headers["X-DPP-Access-Roles"]).to be_nil
      end

      it "logs the read with access rights under its own operation" do
        read(aas_paths.first, as: li_reader)
        read(aas_paths.last, as: au_reader)

        entries = AccessEvent.where(dpp_id: dpp_id, event: "read").order(:id)
        expect(entries.map { |e| [e.reader_did, e.operation, e.status] })
          .to eq([[li_reader, "ReadDPPByIdAsAAS", 200], [au_reader, "ReadDPPByProductIdAsAAS", 200]])
      end

      it "names the passport it comes from and the state of its signature and commitment" do
        read(aas_paths.first)

        view = response.parsed_body
        source = "https://dpp-service.ownyourdata.eu/dpp/v1/dpps/#{ERB::Util.url_encode(dpp_id)}?representation=full"
        expect(shell(view)["id"]).to eq("https://dpp-service.ownyourdata.eu/dpp/v1/dpps/#{ERB::Util.url_encode(dpp_id)}/aas")
        expect(shell(view)["assetInformation"]).to eq("assetKind" => "Instance", "globalAssetId" => product_id)
        expect(extension(view, "sourcePassport")).to eq(source)
        expect(extension(view, "signatureState")).to eq(response.headers["X-DPP-Signature-State"])
        expect(response.headers["Link"]).to eq(%(<#{source}>; rel="via"))
        expect(shell(view)["description"].first["text"]).to include("not signed by the economic operator")
      end

      it "hands out nothing of a controlled part that does not match its digest" do
        card = pod.cards.values.find { |c| c.type == FakePod::CONTROLLED }
        tampered = card.payloads.last.deep_dup
        tampered["elements"].find { |e| e["elementId"] == "SerialNumber" }["value"] = "SN-FORGED"
        card.payloads << tampered
        card.stamps << card.stamps.last

        read(aas_paths.first, as: li_reader)

        expect(response).to have_http_status(:bad_gateway)
        expect(response.body).not_to include("SN-FORGED", "SN-0921")
      end
    end

    describe "a passport in this service's database" do
      before do
        create_locally
        grant_roles!
      end

      it "gives each reader the same attributes as at a custodian" do
        expected.each do |role, attributes|
          read(aas_paths.first, as: who(role))

          expect(property_ids(response.parsed_body)).to eq(attributes)
        end
      end

      it "names the AAS view on ReadDPPById and ReadDPPByProductId" do
        passport_paths.each do |path|
          read(path)

          expect(response.headers["Link"]).to eq(
            %(<https://dpp-service.ownyourdata.eu/dpp/v1/dpps/#{ERB::Util.url_encode(dpp_id)}/aas>; ) +
            %(rel="alternate"; type="application/json"; title="Asset Administration Shell (AAS V3.0)")
          )
        end
      end

      it "refuses the representation flag, which does not apply to the view" do
        read("#{aas_paths.first}?representation=full")

        expect(response).to have_http_status(:bad_request)
        expect(response.parsed_body["message"].first["text"]).to match(/does not apply to the AAS view/)
      end

      it "answers 406 to a client that asks for the signature, and says where the signed passport is" do
        get aas_paths.first, headers: { "Accept" => "application/jose" }

        expect(response).to have_http_status(:not_acceptable)
        expect(response.headers["Link"]).to include('rel="via"')
        expect(AccessEvent.where(dpp_id: dpp_id, event: "read")).to be_empty
      end

      it "stays JSON for a browser and for a client that weighs both alike" do
        ["text/html,application/xhtml+xml,*/*;q=0.8", "application/jose, application/json", "*/*"].each do |accept|
          get aas_paths.first, headers: { "Accept" => accept }

          expect(response).to have_http_status(:ok)
          expect(response.media_type).to eq("application/json")
        end
      end

      it "refuses a token that does not hold with 401" do
        get aas_paths.first, headers: { "Authorization" => "Bearer not-a-token" }

        expect(response).to have_http_status(:unauthorized)
      end

      it "answers 404 for a passport or a product it does not know" do
        read("/dpp/v1/dpps/#{CGI.escape('did:oyd:zQmUnknown')}/aas")
        expect(response).to have_http_status(:not_found)

        read("/dpp/v1/dppsByProductId/#{CGI.escape('https://dpp.oydapp.eu/01/09520123456788/21/999999')}/aas")
        expect(response).to have_http_status(:not_found)
      end
    end
  end

  describe "a battery passport" do
    let(:token) { "Bearer #{JWT.encode({ sub: 'did:oyd:zQmExampleOperator' }, nil, 'none')}" }
    let(:source) { JSON.parse(Rails.root.join("spec/fixtures/aas-vectors/source-battery.json").read) }
    let(:document) do
      source.except("lastUpdated", "dppStatus")
            .merge("digitalProductPassportId" => "https://dpp.oydapp.eu/passports/VOLT-EVP-2026-000916",
                   "uniqueProductIdentifier" => "https://dpp.oydapp.eu/01/09520123456788/21/VOLT-EVP-2026-000916")
    end

    before do
      post "/dpp/v1/dpps", params: document.to_json,
                           headers: { "Content-Type" => "application/json", "Authorization" => token }
      expect(response).to have_http_status(:created)
    end

    it "adds the submodels of the Battery Pass Data Model, as far as the passport fits them" do
      get "/dpp/v1/dpps/#{CGI.escape(document['digitalProductPassportId'])}/aas"

      view = response.parsed_body
      expect(view["submodels"].map { |s| s["idShort"] }).to eq(
        %w[DppMetadata PassportElements GeneralProductInformation CarbonFootprintForBatteries Circularity
           MaterialComposition PerformanceAndDurability SupplyChainDueDiligence]
      )
      general = view["submodels"].find { |s| s["idShort"] == "GeneralProductInformation" }
      expect(general["semanticId"]["keys"].first["value"])
        .to eq("urn:samm:io.BatteryPass.GeneralProductInformation:1.0.0#GeneralProductInformation")
      category = general["submodelElements"].find { |e| e["idShort"] == "batteryCategory" }
      expect(category["value"]).to eq("ev")
      expect(extension(view, "signatureState")).to eq("none")
      metadata = view["submodels"].first["submodelElements"].to_h { |e| [e["idShort"], e["value"]] }
      expect(metadata).to include("digitalProductPassportId" => document["digitalProductPassportId"],
                                  "dppStatus" => "Active", "granularity" => "item")
      expect(metadata["lastUpdate"]).to match(/\A\d{4}-\d{2}-\d{2}T/)
    end
  end

  describe "on the carrier path" do
    let(:carrier_host) { "id.example.org" }
    let(:product_id) { "https://#{carrier_host}/01/09520123456788/21/AAS-0001" }
    let(:token) { "Bearer #{JWT.encode({ sub: 'did:oyd:zQmExampleOperator' }, nil, 'none')}" }

    before do
      allow(CarrierHosts).to receive(:list).and_return([carrier_host])
      document = { "digitalProductPassportId" => "https://#{carrier_host}/passports/AAS-0001",
                   "uniqueProductIdentifier" => product_id, "granularity" => "item",
                   "dppSchemaVersion" => "EN 18223:2026", "economicOperatorId" => "did:oyd:zQmExampleOperator",
                   "elements" => [{ "elementId" => "BrandName", "objectType" => "SingleValuedDataElement",
                                    "value" => "Lumina" }] }
      post "/dpp/v1/dpps", params: document.to_json,
                           headers: { "Content-Type" => "application/json", "Authorization" => token }
      expect(response).to have_http_status(:created)
    end

    it "names the AAS view on the API host" do
      host! carrier_host
      get "/01/09520123456788/21/AAS-0001"

      expect(response).to have_http_status(:ok)
      expect(response.headers["Link"]).to include(
        "<https://dpp-service.ownyourdata.eu/dpp/v1/dpps/#{ERB::Util.url_encode("https://#{carrier_host}/passports/AAS-0001")}/aas>"
      )
    end
  end
end
