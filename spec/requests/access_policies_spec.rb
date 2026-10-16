# frozen_string_literal: true

require "rails_helper"

# Access policies at the API (docs/AccessClasses.md): registered once per
# product type with PUT /dpp/v1/access-policies, named by a passport in
# X-DPP-Access-Policy at CreateDPP or UpdateDPP, kept by this service and never
# in the passport, and reported back as warnings on the owner's writes.
#
# Tokens are verified here (stubbed as in did_auth_spec), because a policy
# belongs to the operator that registered it.
RSpec.describe "Access policies", type: :request do
  let(:owner)    { "did:oyd:zOwnerAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA" }
  let(:stranger) { "did:oyd:zStrangerBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB" }

  let(:dpp_id)     { "https://dpp.lumina.example/01/09520123456788/8546" }
  let(:product_id) { "https://id.lumina.example/01/09520123456788" }
  let(:enc)        { CGI.escape(dpp_id) }

  let(:policy_id) { "https://dpp.example.org/access-policies/led-lamp/1" }
  let(:policy) do
    { "id" => policy_id,
      "title" => "LED lamp",
      "scheme" => "https://w3id.org/soya/dpp-access/v1",
      "rules" => [
        { "path" => "EnergyPerformance", "accessClass" => "public" },
        { "path" => "EnergyPerformance/LuminousFlux", "accessClass" => "legitimateInterest" },
        { "path" => "Recycling", "accessClass" => "authority" }
      ] }
  end

  # Manufacturer is reached by no rule, Recycling reaches no attribute.
  let(:document) do
    { "digitalProductPassportId" => dpp_id,
      "uniqueProductIdentifier" => product_id,
      "granularity" => "model",
      "dppSchemaVersion" => "EN 18223:2026",
      "dppStatus" => "Active",
      "economicOperatorId" => "did:oyd:zQmPPwHJK1NHBz3BS89StWsfrH4pzkyqwJiK94zVj25wXUS",
      "elements" => [
        { "elementId" => "EnergyPerformance", "objectType" => "DataElementCollection",
          "elements" => [
            { "objectType" => "SingleValuedDataElement", "elementId" => "LuminousFlux", "value" => 806 },
            { "objectType" => "SingleValuedDataElement", "elementId" => "EnergyEfficiencyClass", "value" => "E" }
          ] },
        { "objectType" => "SingleValuedDataElement", "elementId" => "Manufacturer", "value" => "Lumina" }
      ] }
  end

  def headers_for(did, extra = {})
    token = JWT.encode({ "iss" => did, "sub" => did }, nil, "none")
    { "Content-Type" => "application/json", "Authorization" => "Bearer #{token}" }.merge(extra)
  end

  def patch_headers_for(did, extra = {})
    headers_for(did, { "Content-Type" => "application/merge-patch+json" }.merge(extra))
  end

  def register(body = policy, as: owner)
    put "/dpp/v1/access-policies", params: body.to_json, headers: headers_for(as)
  end

  # +policy+ is the value of X-DPP-Access-Policy; without it, no header.
  def create_passport(policy: nil, body: document)
    extra = policy.nil? ? {} : { "X-DPP-Access-Policy" => policy }
    post "/dpp/v1/dpps", params: body.to_json, headers: headers_for(owner, extra)
  end

  def warning = response.headers["X-DPP-Access-Policy"]

  before do
    allow(DidTokenVerifier).to receive(:enabled?).and_return(true)
    allow(DidTokenVerifier).to receive(:call) do |token|
      claims = begin
        JWT.decode(token.to_s, nil, false).first
      rescue JWT::DecodeError
        nil
      end
      claims if claims && claims["iss"].to_s.start_with?("did:")
    end
  end

  describe "PUT /dpp/v1/access-policies" do
    it "registers a policy with 201 and answers with it" do
      register

      expect(response).to have_http_status(:created)
      expect(response.parsed_body).to eq(policy)
      expect(RegisteredAccessPolicy.lookup(owner, policy_id)).to be_present
    end

    it "accepts the same policy again with 200 and keeps one copy" do
      register
      register

      expect(response).to have_http_status(:ok)
      expect(RegisteredAccessPolicy.where(policy_id: policy_id).count).to eq(1)
    end

    it "takes members and rules in another order for the same policy" do
      register
      register(policy.merge("rules" => policy["rules"].reverse).to_a.reverse.to_h)

      expect(response).to have_http_status(:ok)
    end

    it "refuses different content under a registered id with 409 and keeps the first" do
      register
      changed = policy.merge("rules" => policy["rules"] + [{ "path" => "Manufacturer", "accessClass" => "public" }])
      register(changed)

      expect(response).to have_http_status(:conflict)
      expect(response.parsed_body["statusCode"]).to eq("ClientResourceConflict")
      expect(response.parsed_body["message"].first["text"]).to match(/new id/)
      expect(RegisteredAccessPolicy.lookup(owner, policy_id).policy.rules.keys).not_to include("Manufacturer")
    end

    it "keeps the policies of two operators with the same id apart" do
      register
      register(policy.merge("rules" => []), as: stranger)

      expect(response).to have_http_status(:created)
      expect(RegisteredAccessPolicy.where(policy_id: policy_id).count).to eq(2)
    end

    {
      "another scheme" => { "scheme" => "https://example.org/other" },
      "a rule on a header attribute" => { "rules" => [{ "path" => "facilityId", "accessClass" => "public" }] },
      "an unknown access class" => { "rules" => [{ "path" => "A", "accessClass" => "secret" }] },
      "an id that is no URI" => { "id" => "led-lamp" },
      "an id longer than a header takes" => { "id" => "https://example.org/#{'a' * 600}" }
    }.each do |what, change|
      it "refuses a policy with #{what} with 400 and registers nothing" do
        register(policy.merge(change))

        expect(response).to have_http_status(:bad_request)
        expect(response.parsed_body["statusCode"]).to eq("ClientErrorBadRequest")
        expect(RegisteredAccessPolicy.count).to eq(0)
      end
    end

    it "refuses a body that is no JSON object with 400" do
      put "/dpp/v1/access-policies", params: "[]", headers: headers_for(owner)

      expect(response).to have_http_status(:bad_request)
    end

    it "needs a token" do
      put "/dpp/v1/access-policies", params: policy.to_json, headers: { "Content-Type" => "application/json" }

      expect(response).to have_http_status(:unauthorized)
      expect(RegisteredAccessPolicy.count).to eq(0)
    end
  end

  describe "CreateDPP with X-DPP-Access-Policy" do
    before { register }

    it "attaches the registered policy to the passport" do
      create_passport(policy: policy_id)

      expect(response).to have_http_status(:created)
      expect(Dpp.find(dpp_id).access_policy_record.policy_id).to eq(policy_id)
    end

    it "reports unclassified attributes and unused rules as counts" do
      create_passport(policy: policy_id)

      expect(warning).to eq("\"#{policy_id}\";unclassified=1;unused-rules=1")
    end

    it "puts nothing of the policy into the passport" do
      create_passport(policy: policy_id)
      with_policy = response.parsed_body

      expect(with_policy.keys - %w[EnergyPerformance Manufacturer])
        .to match_array(document.keys - ["elements"] + ["lastUpdated"])
      expect(response.body).not_to include(policy_id)
    end

    it "refuses an id nobody registered with 400, before anything is created" do
      allow(DidOyd).to receive(:mint)
      create_passport(policy: "https://dpp.example.org/access-policies/unknown/1")

      expect(response).to have_http_status(:bad_request)
      expect(response.parsed_body["message"].first["text"]).to match(/no access policy/)
      expect(Dpp.exists?(dpp_id)).to be(false)
      expect(DidOyd).not_to have_received(:mint)
    end

    it "refuses the id of a policy another operator registered with 400" do
      other = "https://dpp.example.org/access-policies/other/1"
      register(policy.merge("id" => other), as: stranger)

      create_passport(policy: other)

      expect(response).to have_http_status(:bad_request)
      expect(Dpp.exists?(dpp_id)).to be(false)
    end

    it "does not mint a DID for a refused policy" do
      allow(DidOyd).to receive(:mint)
      create_passport(policy: "https://dpp.example.org/nope", body: document.except("digitalProductPassportId"))

      expect(response).to have_http_status(:bad_request)
      expect(DidOyd).not_to have_received(:mint)
      expect(Dpp.count).to eq(0)
    end

    it "refuses an unknown policy before the custodian is asked" do
      pod = instance_double(PodStorage, reachable!: true, ensure_product!: true)
      allow(PodStorage).to receive(:from_header).and_return(pod)

      post "/dpp/v1/dpps", params: document.to_json,
                           headers: headers_for(owner, "X-DPP-Storage" => "{}",
                                                       "X-DPP-Access-Policy" => "https://example.org/x")

      expect(response).to have_http_status(:bad_request)
      expect(pod).not_to have_received(:reachable!)
      expect(pod).not_to have_received(:ensure_product!)
    end

    it "refuses an empty header with 400" do
      create_passport(policy: " ")

      expect(response).to have_http_status(:bad_request)
      expect(Dpp.exists?(dpp_id)).to be(false)
    end

    it "refuses a passport the policy cannot classify with 400" do
      body = document.merge("elements" => document["elements"] + [{ "value" => "no elementId" }])
      create_passport(policy: policy_id, body: body)

      expect(response).to have_http_status(:bad_request)
      expect(response.parsed_body["message"].first["text"]).to match(/elementId/)
      expect(Dpp.exists?(dpp_id)).to be(false)
    end
  end

  describe "CreateDPP without X-DPP-Access-Policy" do
    it "creates the passport as before, without a policy and without the header" do
      create_passport

      expect(response).to have_http_status(:created)
      expect(warning).to be_nil
      expect(Dpp.find(dpp_id).access_policy_record).to be_nil
    end

    it "answers exactly as a create with a policy does, apart from the header" do
      create_passport
      without = [response.status, response.parsed_body.except("lastUpdated")]
      Dpp.find(dpp_id).destroy!

      register
      create_passport(policy: policy_id)

      expect([response.status, response.parsed_body.except("lastUpdated")]).to eq(without)
    end
  end

  describe "read paths" do
    let(:paths) do
      ["/dpp/v1/dpps/#{enc}",
       "/dpp/v1/dpps/#{enc}?representation=full",
       "/dpp/v1/dppsByProductId/#{CGI.escape(product_id)}",
       "/dpp/v1/dpps/#{enc}/elements/EnergyPerformance/EnergyEfficiencyClass",
       "/dpp/v1/dpps/#{enc}/collections/EnergyPerformance",
       "/dpp/v1/dppsByIdAndDate/#{enc}?date=#{CGI.escape(1.minute.from_now.utc.iso8601)}",
       "/.well-known/dpp-service"]
    end

    # Status, body and headers of every read path, without what changes from
    # one request to the next.
    def snapshot
      paths.map do |path|
        get path
        [path, response.status, response.body,
         response.headers.to_h.except("x-request-id", "x-runtime", "X-Request-Id", "X-Runtime")]
      end
    end

    it "never carry the header, and give a reader without access rights the public attributes only" do
      register
      create_passport(policy: policy_id)
      patch "/dpp/v1/dpps/#{enc}", params: {}.to_json, headers: patch_headers_for(owner)
      with_policy = snapshot

      expect(with_policy.first(6).map { |entry| entry[1] }).to all(eq(200))
      expect(with_policy.flat_map { |entry| entry[3].keys.map(&:downcase) }).not_to include("x-dpp-access-policy")
      expect(with_policy.first(6).map { |entry| entry[2] }.join).not_to include("806", "Lumina")
    end

    it "answer as before for a passport without a policy" do
      create_passport
      without_policy = snapshot

      expect(without_policy.first(6).map { |entry| entry[1] }).to all(eq(200))
      expect(without_policy.first(3).map { |entry| entry[2] }).to all(include("806", "Lumina"))
    end
  end

  describe "GET /dpp/v1/dpps/{id}/access-policy" do
    before { register }

    it "lists the unclassified attributes and the unused rules for the owner" do
      create_passport(policy: policy_id)

      get "/dpp/v1/dpps/#{enc}/access-policy", headers: headers_for(owner)

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body).to eq("policy" => policy_id,
                                         "unclassified" => ["Manufacturer"],
                                         "unusedRules" => ["Recycling"])
    end

    it "is not readable for another operator" do
      create_passport(policy: policy_id)

      get "/dpp/v1/dpps/#{enc}/access-policy", headers: headers_for(stranger)

      expect(response).to have_http_status(:forbidden)
    end

    it "needs a token" do
      create_passport(policy: policy_id)

      get "/dpp/v1/dpps/#{enc}/access-policy"

      expect(response).to have_http_status(:unauthorized)
    end

    it "answers 404 for a passport without a policy" do
      create_passport

      get "/dpp/v1/dpps/#{enc}/access-policy", headers: headers_for(owner)

      expect(response).to have_http_status(:not_found)
    end
  end

  describe "later writes" do
    let(:lamp2_id) { "https://dpp.example.org/access-policies/led-lamp/2" }
    let(:lamp2) do
      policy.merge("id" => lamp2_id,
                   "rules" => policy["rules"].first(2) + [{ "path" => "Manufacturer", "accessClass" => "public" }])
    end

    before do
      register
      register(lamp2)
      create_passport(policy: policy_id)
    end

    def policy_of_passport = Dpp.find(dpp_id).access_policy_record.policy_id

    it "UpdateDPP keeps the policy and reports on the new state" do
      patch "/dpp/v1/dpps/#{enc}",
            params: { "elements" => document["elements"].first(1) }.to_json, headers: patch_headers_for(owner)

      expect(response).to have_http_status(:ok)
      expect(policy_of_passport).to eq(policy_id)
      expect(warning).to eq("\"#{policy_id}\";unclassified=0;unused-rules=1")
    end

    it "UpdateDPP with the header and an empty patch replaces the policy" do
      patch "/dpp/v1/dpps/#{enc}", params: {}.to_json,
                                   headers: patch_headers_for(owner, "X-DPP-Access-Policy" => lamp2_id)

      expect(response).to have_http_status(:ok)
      expect(policy_of_passport).to eq(lamp2_id)
      expect(warning).to eq("\"#{lamp2_id}\";unclassified=0;unused-rules=0")
    end

    it "UpdateDPP cannot remove the policy" do
      patch "/dpp/v1/dpps/#{enc}", params: {}.to_json,
                                   headers: patch_headers_for(owner, "X-DPP-Access-Policy" => "")

      expect(response).to have_http_status(:bad_request)
      expect(response.parsed_body["message"].first["text"]).to match(/cannot be removed/)
      expect(policy_of_passport).to eq(policy_id)
    end

    it "UpdateDPP with an unknown policy changes neither the policy nor the passport" do
      patch "/dpp/v1/dpps/#{enc}", params: { "facilityId" => "https://f.example/1" }.to_json,
                                   headers: patch_headers_for(owner, "X-DPP-Access-Policy" => "https://example.org/x")

      expect(response).to have_http_status(:bad_request)
      expect(policy_of_passport).to eq(policy_id)
      expect(Dpp.find(dpp_id).facility_id).to be_nil
    end

    it "UpdateDPP that would leave the passport unclassifiable is refused and changes nothing" do
      patch "/dpp/v1/dpps/#{enc}",
            params: { "elements" => document["elements"] + [{ "value" => 1 }] }.to_json,
            headers: patch_headers_for(owner)

      expect(response).to have_http_status(:bad_request)
      expect(Dpp.find(dpp_id).to_document["elements"].size).to eq(2)
      expect(DppVersion.where(dpp_id: dpp_id).count).to eq(0)
    end

    it "UpdateDataElement reports on the new state" do
      patch "/dpp/v1/dpps/#{enc}/elements/Manufacturer",
            params: { "value" => "Lumina GmbH" }.to_json, headers: patch_headers_for(owner)

      expect(response).to have_http_status(:ok)
      expect(warning).to eq("\"#{policy_id}\";unclassified=1;unused-rules=1")
    end

    it "UpdateDataElement does not take the header" do
      patch "/dpp/v1/dpps/#{enc}/elements/Manufacturer",
            params: { "value" => "Lumina GmbH" }.to_json,
            headers: patch_headers_for(owner, "X-DPP-Access-Policy" => lamp2_id)

      expect(response).to have_http_status(:bad_request)
      expect(policy_of_passport).to eq(policy_id)
      expect(Dpp.find(dpp_id).to_document["elements"].last["value"]).to eq("Lumina")
    end

    it "a collection patch does not take the header either" do
      patch "/dpp/v1/dpps/#{enc}/collections/EnergyPerformance",
            params: { "dictionaryReference" => "https://dictionary.example/ep" }.to_json,
            headers: patch_headers_for(owner, "X-DPP-Access-Policy" => lamp2_id)

      expect(response).to have_http_status(:bad_request)
      expect(policy_of_passport).to eq(policy_id)
    end

    it "DeleteDPPById leaves the registered policy in place" do
      delete "/dpp/v1/dpps/#{enc}", headers: headers_for(owner)

      expect(response).to have_http_status(:no_content)
      expect(RegisteredAccessPolicy.lookup(owner, policy_id)).to be_present
    end
  end

  describe "without verified tokens" do
    before { allow(DidTokenVerifier).to receive(:enabled?).and_return(false) }

    it "registers and attaches a policy that belongs to nobody" do
      register
      expect(response).to have_http_status(:created)

      create_passport(policy: policy_id)

      expect(response).to have_http_status(:created)
      expect(RegisteredAccessPolicy.lookup(nil, policy_id)).to be_present
      expect(warning).to start_with("\"#{policy_id}\"")
    end
  end
end
