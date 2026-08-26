# frozen_string_literal: true

require "rails_helper"

# The identifier the data carrier bears.
#
# EN 18219:2026 3.1.25 makes the unique product identifier one string that both
# identifies the product and enables the web link to the passport, and
# §4.5.2 (1) requires that same string to be retrievable from the carrier.
# There is therefore no separate carrier token to derive: the UPI *is* the
# ProductID (docs/Identifiers.md).
RSpec.describe "Carrier identifier", type: :request do
  let(:token) { "Bearer #{JWT.encode({ sub: 'did:oyd:zQmPPwHJK1NHBz3BS89StWsfrH4pzkyqwJiK94zVj25wXUS', scope: 'dpp:write' }, nil, 'none')}" }
  let(:auth)  { { "Content-Type" => "application/json", "Authorization" => token } }

  # 49 characters: 8 + len("dpp.oydapp.eu") + len("/01/") + 14 + len("/21/") + 6.
  # The host belongs to the economic operator and is pointed at the custodian
  # by CNAME, which is what keeps a printed carrier alive across a change of
  # custodian (§4.6.2 (3), §4.5.2 (4), §3.12).
  let(:product_id) { "https://dpp.oydapp.eu/01/09520123456791/21/000123" }

  let(:dpp_document) do
    {
      "digitalProductPassportId" => "did:oyd:zQmWVzyTPZ19ebpw2Dm9doEDP4qw9rVcs6M4v3iQMo7vpVS",
      "uniqueProductIdentifier" => product_id,
      "granularity" => "item",
      "dppSchemaVersion" => "EN 18223:2026",
      "economicOperatorId" => "did:oyd:zQmPPwHJK1NHBz3BS89StWsfrH4pzkyqwJiK94zVj25wXUS"
    }
  end

  # The documents here carry a client-supplied did:oyd. Resolving it is checked
  # in dpp_did_spec; what is under test here is the carrier identifier, so the
  # resolution is stubbed away rather than reached over the network.
  before { allow(DidOyd).to receive(:assert_endpoint_host!).and_return(true) }

  def create_dpp!(doc = dpp_document)
    post "/dpp/v1/dpps", params: doc.to_json, headers: auth
    JSON.parse(response.body)
  end

  describe "the identifier itself" do
    it "is the uniqueProductIdentifier, and stays within the Registry's 50-character limit" do
      body = create_dpp!
      expect(response).to have_http_status(:created)
      expect(body["uniqueProductIdentifier"]).to eq(product_id)
      expect(product_id.length).to be <= 50
    end

    it "carries no separate UPI attribute, which EN 18223:2026 Table 1 does not define" do
      body = create_dpp!
      expect(body).not_to have_key("UPI")
    end

    it "records the host-independent path as the lookup key for the custodian" do
      create_dpp!
      expect(Dpp.find_by(product_id: product_id).product_key)
        .to eq("/01/09520123456791/21/000123")
    end
  end

  describe "refusals at creation" do
    it "refuses an identifier that would not fit on the carrier" do
      long = "https://dpp.a-rather-long-operator-domain.example/01/09520123456791/21/000123"
      create_dpp!(dpp_document.merge("uniqueProductIdentifier" => long))

      expect(response).to have_http_status(:bad_request)
      expect(response.body).to match(/over the 50-character limit/)
    end

    it "refuses a granularity the path contradicts" do
      create_dpp!(dpp_document.merge("granularity" => "model"))

      expect(response).to have_http_status(:bad_request)
      expect(response.body).to match(/contradicts the identifier path/)
    end

    it "refuses a malformed Digital Link rather than reading it as free text" do
      create_dpp!(dpp_document.merge("uniqueProductIdentifier" => "https://dpp.oydapp.eu/01/952012345679"))

      expect(response).to have_http_status(:bad_request)
      expect(response.body).to match(/Digital Link/)
    end

    it "refuses a path with characters a carrier cannot bear unencoded" do
      create_dpp!(dpp_document.merge("uniqueProductIdentifier" => "https://dpp.oydapp.eu/ABC 4711"))

      expect(response).to have_http_status(:bad_request)
    end

    it "refuses plain http" do
      create_dpp!(dpp_document.merge("uniqueProductIdentifier" => "http://dpp.oydapp.eu/01/09520123456791"))

      expect(response).to have_http_status(:bad_request)
    end
  end

  # EN 18219:2026 5.3: an operator with no GS1 membership can issue its own
  # identifier under a domain it controls. Supporting only §5.1 would make the
  # architecture's freedom from lock-in stop at the domain name and continue as
  # a dependency on an annually licensed prefix.
  describe "identification links (EN 18219:2026 5.3)" do
    let(:self_issued) { "https://dpp.oydapp.eu/ABC-4711" }

    it "is accepted with a declared granularity" do
      body = create_dpp!(dpp_document.merge("uniqueProductIdentifier" => self_issued,
                                            "granularity" => "batch"))

      expect(response).to have_http_status(:created)
      expect(body["uniqueProductIdentifier"]).to eq(self_issued)
      expect(Dpp.find_by(product_id: self_issued).product_key).to eq("/ABC-4711")
    end
  end
end
