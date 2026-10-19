# frozen_string_literal: true

require "rails_helper"
require "digest"
require_relative "../support/fake_pod"

# A passport with an access policy, held by a custodian that holds controlled
# cards, is written as two cards in one collection under one write delegation:
# the public DigitalProductPassport and the DigitalProductPassportControlled
# with everything that is not public (docs/AccessClasses.md, PassportSplit).
#
# The pod client is real; the custodians are FakePod instances behind
# OutboundHttp, so what reaches them, and in which order, is visible. Both
# custodians that hold controlled cards have entered this service as reader
# unless an example says otherwise (ReaderAdmission).
RSpec.describe "Public and controlled card", type: :request do
  let(:held)    { "https://dpp-staging.go-data.at" }
  let(:held2)   { "https://dpp-vault.example" }
  let(:plain)   { "https://dpp.go-data.at" }
  let(:pods)    { [held, held2, plain].to_h { |url| [url, FakePod.new(url)] } }
  let(:pod)     { pods[held] }

  let(:product_id) { "https://dpp.oydapp.eu/01/09520123456795/21/000777" }
  let(:dpp_id)     { "did:oyd:zQmControlledCard777" }
  let(:enc)        { CGI.escape(dpp_id) }
  let(:bearer)     { "Bearer #{JWT.encode({ sub: 'did:oyd:zOwner', scope: 'dpp:write' }, nil, 'none')}" }

  let(:holder)      { Ed25519::SigningKey.new(Digest::SHA256.digest("controlled-card/holder")) }
  let(:service_key) { Ed25519::SigningKey.new(Digest::SHA256.digest("controlled-card/service")) }

  let(:held_reader) do
    instance_double(ReaderDid, did: "did:oyd:zQmReader", pod: held,
                               signing_key: Ed25519::SigningKey.new(Digest::SHA256.digest("controlled-card/reader")))
  end
  let(:held2_reader) do
    instance_double(ReaderDid, did: "did:oyd:zQmReader2", pod: held2,
                               signing_key: Ed25519::SigningKey.new(Digest::SHA256.digest("controlled-card/reader2")))
  end

  let(:policy_doc) do
    { "id" => "https://dpp.example.org/access-policies/lamp/1",
      "scheme" => AccessClass::SCHEME,
      "rules" => [
        { "path" => "ProductIdentification", "accessClass" => "public" },
        { "path" => "ProductIdentification/BatchNumber", "accessClass" => "legitimateInterest" },
        { "path" => "Composition", "accessClass" => "authority" },
        { "path" => "EnergyPerformance", "accessClass" => "public" },
        { "path" => "RecycledContent", "accessClass" => "legitimateInterest" }
      ] }
  end
  let(:policy) { RegisteredAccessPolicy.register!(nil, policy_doc).first }

  def single(id, value) = { "elementId" => id, "objectType" => "SingleValuedDataElement", "value" => value }

  def collection(id, *children)
    { "elementId" => id, "objectType" => "DataElementCollection", "elements" => children }
  end

  let(:document) do
    { "uniqueProductIdentifier" => product_id,
      "granularity" => "item",
      "dppSchemaVersion" => "EN 18223:2026",
      "dppStatus" => "Active",
      "economicOperatorId" => "did:oyd:zQmPPwHJK1NHBz3BS89StWsfrH4pzkyqwJiK94zVj25wXUS",
      "elements" => [
        collection("ProductIdentification", single("ModelIdentifier", "LUM-A60"), single("BatchNumber", "LOT-42")),
        collection("Composition", single("MaterialComposition", "PC 61 %")),
        collection("EnergyPerformance", single("LuminousFlux", 806)),
        single("RecycledContent", 12)
      ] }
  end

  def mandate(base_url, collection_id = "4", exp: Time.now.to_i + (30 * 86_400), act: %w[create update delete])
    now = Time.now.to_i
    Delegation.sign(holder, typ: Delegation::TYP_DELEGATION, kid: "did:oyd:zHolder#key-doc",
                            payload: { "iss" => "did:oyd:zHolder", "sub" => "did:oyd:zService",
                                       "aud" => base_url, "collection" => collection_id,
                                       "product_id" => product_id, "act" => act, "purpose" => "dpp-hosting",
                                       "iat" => [exp, now].min - 3600, "nbf" => [exp, now].min - 3600,
                                       "exp" => exp, "jti" => SecureRandom.hex(8) })
  end

  def storage_header(base_url, collection_id = "4", **opts)
    { base_url: base_url, collection_id: collection_id, delegation: mandate(base_url, collection_id, **opts) }.to_json
  end

  def create_passport(base_url: held, with_policy: true, body: document)
    headers = { "Content-Type" => "application/json", "Authorization" => bearer,
                "X-DPP-Storage" => storage_header(base_url) }
    headers["X-DPP-Access-Policy"] = policy.policy_id if with_policy
    post "/dpp/v1/dpps?representation=full", params: body.to_json, headers: headers
  end

  def patch_passport(patch, extra = {})
    patch "/dpp/v1/dpps/#{enc}?representation=full",
          params: patch.to_json,
          headers: { "Content-Type" => "application/merge-patch+json", "Authorization" => bearer }.merge(extra)
  end

  def paths(doc) = PassportSplit.attribute_paths(doc)
  def value_at(doc, *ids) = ElementIdPath.parse(ids.join("/")).resolve(doc)&.fetch("value", nil)
  def types_written(fake = pod) = fake.writes.map { |_, type, _| type }

  before do
    PodStorage.reset_token_cache!
    allow(ServiceDid).to receive(:did).and_return("did:oyd:zService")
    allow(ServiceDid).to receive(:signing_key).and_return(service_key)
    allow(PodStorage).to receive(:from_header) { |raw, **| PodStorage.from_hash(JSON.parse(raw), verify: false) }
    allow(DidOyd).to receive(:mint).and_return({ did: dpp_id, doc_key: "doc", rev_key: "rev", rev_log: "log" })
    allow(DidOyd).to receive(:revoke)
    allow(ENV).to receive(:[]).and_call_original
    allow(ENV).to receive(:[]).with("DPP_CONTROLLED_CARD_PODS").and_return("#{held}, #{held2}")
    allow(ReaderDid).to receive(:for_pod) { |url| { held => held_reader, held2 => held2_reader }[url] }
    pods[held].readers << held_reader.did
    pods[held2].readers << held2_reader.did
    allow(OutboundHttp).to receive(:perform) do |req, **|
      fake = pods.values.find { |p| p.handles?(req) } || raise("no custodian for #{req.url}")
      status, body = fake.call(req)
      OutboundHttp::Response.new(code: status.to_s, body: body.is_a?(String) ? body : JSON.generate(body),
                                 message: "stubbed", version: "2.0")
    end
  end

  describe "creating on a custodian that holds controlled cards" do
    before { create_passport }

    it "writes the controlled card first, then the public card" do
      expect(response).to have_http_status(:created)
      expect(types_written).to eq([FakePod::CONTROLLED, FakePod::PUBLIC])
    end

    it "gives both cards the passport identifier and the product identifier" do
      cards = pod.cards.values
      expect(cards.map(&:type)).to contain_exactly(FakePod::CONTROLLED, FakePod::PUBLIC)
      expect(cards.map(&:dpp_id).uniq).to eq([dpp_id])
      expect(cards.map(&:upi).uniq).to eq([product_id])
    end

    it "puts only public attributes on the public card" do
      expect(paths(pod.public_payload(dpp_id)))
        .to contain_exactly("ProductIdentification/ModelIdentifier", "EnergyPerformance/LuminousFlux")
      expect(pod.public_payload(dpp_id).to_json).not_to include("LOT-42", "PC 61", "RecycledContent")
    end

    it "puts every other attribute, of both classes, on the controlled card" do
      expect(paths(pod.controlled_payload(dpp_id)))
        .to contain_exactly("ProductIdentification/BatchNumber", "Composition/MaterialComposition", "RecycledContent")
    end

    it "keeps the full header on both cards" do
      public_hull = pod.public_payload(dpp_id).except("elements")
      expect(public_hull.keys).to include("digitalProductPassportId", "uniqueProductIdentifier", "lastUpdated")
      expect(pod.controlled_payload(dpp_id).except("elements")).to eq(public_hull)
    end

    it "names the controlled payload in the public one by a salted digest" do
      controlled = pod.controlled_payload(dpp_id)
      named = PassportSplit.named_digest(pod.public_payload(dpp_id))

      expect(named).to eq(PassportSplit.digest(controlled))
      salt = controlled["elements"].find { |e| e["elementId"] == "ControlledDataSalt" }
      expect(salt["value"]).to match(/\A[A-Za-z0-9_-]{22}\z/)
    end

    it "stores the object id of the controlled card" do
      controlled = pod.cards.values.find { |c| c.type == FakePod::CONTROLLED }
      expect(Dpp.find(dpp_id).storage_controlled_object_id).to eq(controlled.id)
    end

    it "gives the owner the whole passport back, without the service's elements" do
      body = response.parsed_body
      expect(paths(body)).to include("ProductIdentification/BatchNumber", "RecycledContent")
      expect(body.to_json).not_to include("ControlledData")
    end

    it "gives readers only the public card" do
      get "/dpp/v1/dpps/#{enc}?representation=full"
      expect(response).to have_http_status(:ok)
      expect(paths(response.parsed_body))
        .to contain_exactly("ProductIdentification/ModelIdentifier", "EnergyPerformance/LuminousFlux")

      get "/dpp/v1/dppsByProductId/#{CGI.escape(product_id)}"
      expect(response.body).not_to include("LOT-42")

      get "/dpp/v1/dpps/#{enc}/elements/ProductIdentification/BatchNumber"
      expect(response).to have_http_status(:not_found)
    end
  end

  describe "refusals at create" do
    it "refuses a passport whose policy leaves attributes that are not public on a custodian that would publish them" do
      create_passport(base_url: plain)

      expect(response).to have_http_status(:bad_request)
      expect(response.parsed_body["message"].first["text"]).to match(/would publish them/)
      expect(response.parsed_body["message"].first).not_to have_key("code")
      expect(pods[plain].log.grep(/object/)).to be_empty
      expect(DidOyd).not_to have_received(:mint)
      expect(Dpp.count).to eq(0)
    end

    it "takes a policy that leaves everything public on such a custodian, as one card" do
      public_policy = RegisteredAccessPolicy.register!(nil, policy_doc.merge("id" => "https://dpp.example.org/p/2",
                                                                             "default" => "public", "rules" => [])).first
      post "/dpp/v1/dpps", params: document.to_json,
                           headers: { "Content-Type" => "application/json", "Authorization" => bearer,
                                      "X-DPP-Storage" => storage_header(plain),
                                      "X-DPP-Access-Policy" => public_policy.policy_id }

      expect(response).to have_http_status(:created)
      expect(types_written(pods[plain])).to eq([FakePod::PUBLIC])
    end

    it "writes one public card for a passport without a policy" do
      create_passport(with_policy: false)

      expect(response).to have_http_status(:created)
      expect(types_written).to eq([FakePod::PUBLIC])
      expect(PassportSplit.named_digest(pod.public_payload(dpp_id))).to be_nil
      expect(Dpp.find(dpp_id).storage_controlled_object_id).to be_nil
    end

    it "answers V10 with its own conflict and leaves nothing behind" do
      pod.refuse_controlled = [409, { "error" => "passport identifier is held by another collection" }]
      create_passport

      expect(response).to have_http_status(:conflict)
      expect(response.parsed_body["statusCode"]).to eq("ClientResourceConflict")
      expect(response.parsed_body["message"].first["text"]).to match(/collection of another economic operator/)
      expect(pod.cards.values.map(&:type)).to be_empty
      expect(DidOyd).to have_received(:revoke)
      expect(Dpp.count).to eq(0)
    end

    it "answers a delegation that does not cover the controlled card with 403" do
      pod.refuse_controlled = [403, { "error" => "insufficient_scope" }]
      create_passport

      expect(response).to have_http_status(:forbidden)
      expect(response.parsed_body["message"].first["text"]).to match(/does not cover the controlled card/)
      expect(pod.writes).to be_empty
    end

    it "removes the controlled card again when the public card cannot be written" do
      pod.fail_write = ->(card) { [500, { "error" => "boom" }] if card.type == FakePod::PUBLIC }
      create_passport

      expect(response).to have_http_status(:bad_gateway)
      expect(pod.live(FakePod::CONTROLLED)).to be_empty
      expect(Dpp.count).to eq(0)
    end
  end

  describe "changing a split passport" do
    before do
      create_passport
      pod.writes.clear
    end

    it "reads the controlled card with the write delegation before the change" do
      patch_passport({ "facilityId" => "https://id.lumina.example/414/1" })

      expect(response).to have_http_status(:ok)
      read = pod.headers.find { |method, path, _| method == :get && path.end_with?("/read") }
      expect(read.last).to start_with("DPoP ")
    end

    it "keeps the controlled values through an UpdateDPP" do
      patch_passport({ "facilityId" => "https://id.lumina.example/414/1" })

      expect(types_written).to eq([FakePod::CONTROLLED, FakePod::PUBLIC])
      expect(value_at(pod.controlled_payload(dpp_id), "ProductIdentification", "BatchNumber")).to eq("LOT-42")
      expect(pod.public_payload(dpp_id)["facilityId"]).to eq("https://id.lumina.example/414/1")
      expect(PassportSplit.named_digest(pod.public_payload(dpp_id)))
        .to eq(PassportSplit.digest(pod.controlled_payload(dpp_id)))
    end

    it "changes a controlled value through UpdateDataElement" do
      patch "/dpp/v1/dpps/#{enc}/elements/ProductIdentification/BatchNumber",
            params: { "value" => "LOT-43" }.to_json,
            headers: { "Content-Type" => "application/merge-patch+json", "Authorization" => bearer }

      expect(response).to have_http_status(:ok)
      expect(value_at(pod.controlled_payload(dpp_id), "ProductIdentification", "BatchNumber")).to eq("LOT-43")
      expect(pod.public_payload(dpp_id).to_json).not_to include("LOT-43")
    end

    it "moves an attribute to the controlled card under a stricter policy" do
      stricter = RegisteredAccessPolicy.register!(nil, policy_doc.merge(
        "id" => "https://dpp.example.org/access-policies/lamp/2",
        "rules" => policy_doc["rules"].map { |r| r["path"] == "EnergyPerformance" ? r.merge("accessClass" => "authority") : r }
      )).first
      patch_passport({}, "X-DPP-Access-Policy" => stricter.policy_id)

      expect(response).to have_http_status(:ok)
      expect(types_written).to eq([FakePod::CONTROLLED, FakePod::PUBLIC])
      expect(paths(pod.controlled_payload(dpp_id))).to include("EnergyPerformance/LuminousFlux")
      expect(paths(pod.public_payload(dpp_id))).to eq(["ProductIdentification/ModelIdentifier"])
    end

    context "under a looser policy" do
      let(:looser) do
        RegisteredAccessPolicy.register!(nil, policy_doc.merge(
          "id" => "https://dpp.example.org/access-policies/lamp/3",
          "rules" => policy_doc["rules"].reject { |r| r["path"] == "ProductIdentification/BatchNumber" }
        )).first
      end

      it "writes the leaving attribute to both cards before it leaves the controlled one" do
        patch_passport({}, "X-DPP-Access-Policy" => looser.policy_id)

        expect(response).to have_http_status(:ok)
        expect(types_written).to eq([FakePod::CONTROLLED, FakePod::PUBLIC, FakePod::CONTROLLED])
        first, = pod.writes.first.last.then { |payload| [payload] }
        expect(paths(first)).to include("ProductIdentification/BatchNumber")
        expect(paths(pod.controlled_payload(dpp_id))).not_to include("ProductIdentification/BatchNumber")
        expect(value_at(pod.public_payload(dpp_id), "ProductIdentification", "BatchNumber")).to eq("LOT-42")
        expect(PassportSplit.named_digest(pod.public_payload(dpp_id)))
          .to eq(PassportSplit.digest(pod.controlled_payload(dpp_id)))
      end

      it "loses nothing and publishes nothing early when the public card cannot be written, and gets there on a retry" do
        pod.fail_write = ->(card) { [500, { "error" => "boom" }] if card.type == FakePod::PUBLIC }
        patch_passport({}, "X-DPP-Access-Policy" => looser.policy_id)

        expect(response).to have_http_status(:bad_gateway)
        expect(pod.public_payload(dpp_id).to_json).not_to include("LOT-42")
        whole = Dpp.find(dpp_id).to_document
        expect(value_at(whole, "ProductIdentification", "BatchNumber")).to eq("LOT-42")
        expect(paths(whole)).to include("RecycledContent", "Composition/MaterialComposition")

        pod.fail_write = nil
        patch_passport({}, "X-DPP-Access-Policy" => looser.policy_id)

        expect(response).to have_http_status(:ok)
        expect(value_at(pod.public_payload(dpp_id), "ProductIdentification", "BatchNumber")).to eq("LOT-42")
        expect(paths(pod.controlled_payload(dpp_id))).not_to include("ProductIdentification/BatchNumber")
      end
    end

    context "when the object id of the controlled card is lost" do
      let(:reader_key) { Ed25519::SigningKey.new(Digest::SHA256.digest("controlled-card/reader")) }
      let(:reader) do
        instance_double(ReaderDid, did: "did:oyd:zQmReader", pod: held, signing_key: reader_key)
      end

      before do
        allow(ReaderDid).to receive(:for_pod).with(held).and_return(reader)
        Dpp.find(dpp_id).update_column(:storage_controlled_object_id, nil)
      end

      it "looks it up under the read grant, because the write token may not list objects" do
        pod.readers << reader.did

        patch_passport({ "facilityId" => "https://id.lumina.example/414/2" })

        expect(response).to have_http_status(:ok)
        expect(pod.grants.map { |claims| claims["iss"] }).to eq([reader.did])
        controlled = pod.live(FakePod::CONTROLLED).first
        expect(Dpp.find(dpp_id).storage_controlled_object_id).to eq(controlled.id)
        expect(value_at(pod.controlled_payload(dpp_id), "ProductIdentification", "BatchNumber")).to eq("LOT-42")
      end

      it "writes nothing and says why when the custodian has removed this service as reader meanwhile" do
        pod.readers.clear
        pod.withdraw_read_tokens!

        patch_passport({ "facilityId" => "https://id.lumina.example/414/5" })

        expect(response).to have_http_status(:bad_gateway)
        expect(response.parsed_body["message"].first["text"]).to match(/could not be looked up.*protected reader/)
        expect(pod.writes).to be_empty
      end
    end

    it "takes the more recently changed of two controlled cards" do
      reader = instance_double(ReaderDid, did: "did:oyd:zQmReader", pod: held,
                                          signing_key: Ed25519::SigningKey.new(Digest::SHA256.digest("controlled-card/reader")))
      allow(ReaderDid).to receive(:for_pod).with(held).and_return(reader)
      pod.readers << reader.did
      stale = pod.put_card(FakePod::CONTROLLED, dpp_id, product_id,
                           { "elements" => [single("RecycledContent", 99)] })
      real = pod.cards.values.find { |c| c.type == FakePod::CONTROLLED && c != stale }
      real.updated_at = stale.updated_at + 10
      Dpp.find(dpp_id).update_column(:storage_controlled_object_id, nil)

      patch_passport({ "facilityId" => "https://id.lumina.example/414/3" })

      expect(response).to have_http_status(:ok)
      expect(Dpp.find(dpp_id).storage_controlled_object_id).to eq(real.id)
      expect(value_at(real.payloads.last, "RecycledContent")).to eq(12)
    end

    it "deletes both cards with the passport" do
      delete "/dpp/v1/dpps/#{enc}", headers: { "Authorization" => bearer }

      expect(response).to have_http_status(:no_content)
      expect(pod.cards.values.map(&:deleted)).to all(be(true))
    end

    it "refuses to write once the custodian is no longer listed as holding controlled cards" do
      allow(ENV).to receive(:[]).with("DPP_CONTROLLED_CARD_PODS").and_return("")

      patch_passport({ "facilityId" => "https://id.lumina.example/414/4" })

      expect(response).to have_http_status(:bad_request)
      expect(pod.writes).to be_empty
    end
  end

  it "splits a passport from the write that attaches a policy to it" do
    create_passport(with_policy: false)
    expect(pod.public_payload(dpp_id).to_json).to include("LOT-42")
    pod.writes.clear

    patch_passport({}, "X-DPP-Access-Policy" => policy.policy_id)

    expect(response).to have_http_status(:ok)
    expect(types_written).to eq([FakePod::CONTROLLED, FakePod::PUBLIC])
    expect(pod.public_payload(dpp_id).to_json).not_to include("LOT-42")
    expect(pod.log).not_to include("GET /collection/4/objects")
  end

  describe "changing the custodian" do
    before do
      create_passport
      pod.writes.clear
    end

    def move(to, query = "", **opts)
      post "/dpp/v1/dpps/#{enc}/custody#{query}",
           headers: { "Authorization" => bearer, "X-DPP-Storage" => storage_header(to, "9", **opts) }
    end

    it "takes the controlled card along, written first" do
      move(held2)

      expect(response).to have_http_status(:ok)
      expect(types_written(pods[held2])).to eq([FakePod::CONTROLLED, FakePod::PUBLIC])
      expect(value_at(pods[held2].controlled_payload(dpp_id), "ProductIdentification", "BatchNumber")).to eq("LOT-42")
      expect(pods[held2].public_payload(dpp_id).to_json).not_to include("LOT-42")
      dpp = Dpp.find(dpp_id)
      expect(dpp.storage_controlled_object_id).to eq(pods[held2].live(FakePod::CONTROLLED).first.id)
    end

    it "releases both cards at the previous custodian when asked" do
      move(held2, "?release_previous=true")

      expect(response).to have_http_status(:ok)
      expect(pod.cards.values.map(&:deleted)).to all(be(true))
    end

    it "refuses a custodian that would publish the controlled part" do
      move(plain)

      expect(response).to have_http_status(:bad_request)
      expect(pods[plain].writes).to be_empty
      expect(Dpp.find(dpp_id).storage_base_url).to eq(held)
    end

    it "says what to do when the mandate for the current custodian has run out" do
      Dpp.find(dpp_id).update_column(:storage_delegation, mandate(held, exp: Time.now.to_i - 86_400))

      move(held2)

      expect(response).to have_http_status(:unauthorized)
      expect(response.parsed_body["message"].first["text"]).to match(/renew it/)
      expect(pods[held2].writes).to be_empty
    end
  end

  describe "the reader of the target collection" do
    include ActiveSupport::Testing::TimeHelpers

    after { travel_back }

    def create_in(collection_id, base_url: held)
      post "/dpp/v1/dpps?representation=full",
           params: document.to_json,
           headers: { "Content-Type" => "application/json", "Authorization" => bearer,
                      "X-DPP-Storage" => storage_header(base_url, collection_id),
                      "X-DPP-Access-Policy" => policy.policy_id }
    end

    def message = response.parsed_body["message"].first["text"]
    def code = response.parsed_body["message"].first["code"]
    def objects_touched(fake = pod) = fake.log.grep(%r{\A(POST|PUT|DELETE) /object})

    it "is asked under the read grant for the collection of the mandate, and the passport is written where it is entered" do
      create_passport

      expect(response).to have_http_status(:created)
      expect(pod.grants.map { |claims| [claims["iss"], claims["collections"]] }).to eq([[held_reader.did, ["4"]]])
      expect(types_written).to eq([FakePod::CONTROLLED, FakePod::PUBLIC])
    end

    it "refuses a passport for a collection without that reader, says what to do, and writes and mints nothing" do
      pod.readers.clear

      create_passport

      expect(response).to have_http_status(:bad_request)
      expect(response.parsed_body["statusCode"]).to eq("ClientErrorBadRequest")
      expect(code).to eq("readerNotEntered")
      expect(message).to start_with("Refused: the custodian at #{held} has no reader entered for collection 4")
      expect(message).to include("3 attribute(s) of this passport that are not public", "Nothing was written",
                                 "ask the custodian to enter this service's reader #{held_reader.did}")
      expect(objects_touched).to be_empty
      expect(pod.cards).to be_empty
      expect(DidOyd).not_to have_received(:mint)
      expect(Dpp.count).to eq(0)
    end

    it "asks for the target collection, not for the custodian as a whole" do
      pod.readers.clear
      pod.collection_readers["5"] << held_reader.did

      create_in("4")
      expect(response).to have_http_status(:bad_request)
      expect(objects_touched).to be_empty

      create_in("5")
      expect(response).to have_http_status(:created)
      expect(types_written).to eq([FakePod::CONTROLLED, FakePod::PUBLIC])
    end

    it "does not ask for a passport whose policy leaves every attribute public" do
      pod.readers.clear
      open_policy = RegisteredAccessPolicy.register!(nil, policy_doc.merge("id" => "https://dpp.example.org/p/open",
                                                                           "default" => "public", "rules" => [])).first
      post "/dpp/v1/dpps", params: document.to_json,
                           headers: { "Content-Type" => "application/json", "Authorization" => bearer,
                                      "X-DPP-Storage" => storage_header(held),
                                      "X-DPP-Access-Policy" => open_policy.policy_id }

      expect(response).to have_http_status(:created)
      expect(pod.grants).to be_empty
    end

    it "keeps an entered reader for a while: a later write does not ask again" do
      create_passport
      PodStorage.reset_token_cache!
      travel(ReaderAdmission::ADMITTED_TTL - 30)

      patch_passport({ "facilityId" => "https://id.lumina.example/414/6" })

      expect(response).to have_http_status(:ok)
      expect(pod.grants.size).to eq(1)
    end

    it "refuses an update once the reader is gone, after the kept answer has run out, and writes nothing" do
      create_passport
      pod.writes.clear
      pod.readers.clear
      PodStorage.reset_token_cache!
      travel(ReaderAdmission::ADMITTED_TTL + 1)

      patch_passport({ "facilityId" => "https://id.lumina.example/414/7" })

      expect(response).to have_http_status(:bad_request)
      expect(message).to match(/no reader entered for collection 4/)
      expect(code).to eq("readerNotEntered")
      expect(pod.writes).to be_empty
      expect(pod.public_payload(dpp_id)["facilityId"]).to be_nil
    end

    it "keeps a missing reader only briefly" do
      pod.readers.clear
      create_passport
      expect(response).to have_http_status(:bad_request)

      pod.readers << held_reader.did
      create_passport
      expect(response).to have_http_status(:bad_request)
      expect(pod.grants.size).to eq(1)

      travel(ReaderAdmission::REFUSED_TTL + 1)
      create_passport
      expect(response).to have_http_status(:created)
      expect(pod.grants.size).to eq(2)
    end

    it "moves a passport only to a collection at which the new custodian has entered the reader" do
      create_passport
      pods[held2].readers.clear

      post "/dpp/v1/dpps/#{enc}/custody",
           headers: { "Authorization" => bearer, "X-DPP-Storage" => storage_header(held2, "9") }

      expect(response).to have_http_status(:bad_request)
      expect(message).to match(/custodian at #{Regexp.escape(held2)} has no reader entered for collection 9/)
      expect(code).to eq("readerNotEntered")
      expect(objects_touched(pods[held2])).to be_empty
      expect(Dpp.find(dpp_id).storage_base_url).to eq(held)
    end

    it "refuses with 502 and writes nothing when the custodian cannot be asked, and asks again next time" do
      pod.unreachable = true

      create_passport

      expect(response).to have_http_status(:bad_gateway)
      expect(response.parsed_body["statusCode"]).to eq("ServerErrorBadGateway")
      expect(message).to match(/entered as reader of collection 4 .* could not be checked .* nothing was written/)
      expect(code).to be_nil
      expect(DidOyd).not_to have_received(:mint)
      expect(Dpp.count).to eq(0)

      pod.unreachable = false
      create_passport
      expect(response).to have_http_status(:created)
    end

    it "refuses with 500 when no reader DID is configured for a custodian that holds controlled cards" do
      allow(ReaderDid).to receive(:for_pod).and_return(nil)

      create_passport

      expect(response).to have_http_status(:internal_server_error)
      expect(message).to match(/no reader DID for the custodian at #{Regexp.escape(held)}.*nothing was written/)
      expect(code).to be_nil
      expect(pod.log).to be_empty
      expect(Dpp.count).to eq(0)
    end
  end

  describe "a local passport with a policy" do
    let(:local_id) { "https://dpp.lumina.example/x/1" }

    before do
      post "/dpp/v1/dpps?representation=full",
           params: document.merge("digitalProductPassportId" => local_id).to_json,
           headers: { "Content-Type" => "application/json", "Authorization" => bearer,
                      "X-DPP-Access-Policy" => policy.policy_id }
    end

    it "is kept as a public and a controlled part, like at a custodian that holds controlled cards" do
      expect(response).to have_http_status(:created)
      dpp = Dpp.find(local_id)

      expect(paths(dpp.content))
        .to contain_exactly("ProductIdentification/ModelIdentifier", "EnergyPerformance/LuminousFlux")
      expect(paths(dpp.controlled_content))
        .to contain_exactly("ProductIdentification/BatchNumber", "Composition/MaterialComposition", "RecycledContent")
      expect(PassportSplit.named_digest(dpp.content)).to eq(PassportSplit.digest(dpp.controlled_content))
    end

    it "gives the owner the whole passport back from the write" do
      expect(paths(response.parsed_body)).to include("ProductIdentification/BatchNumber", "RecycledContent")
      expect(response.body).not_to include("ControlledData")
    end

    it "gives a reader without access rights its public part, naming the controlled one" do
      get "/dpp/v1/dpps/#{CGI.escape(local_id)}?representation=full"

      expect(response.body).not_to include("LOT-42", "PC 61")
      expect(PassportSplit.named_digest(response.parsed_body)).to be_present
    end

    it "does not split again when nothing changed" do
      dpp = Dpp.find(local_id)
      before = dpp.content

      dpp.update!(payload_hash: "z123")

      expect(dpp.reload.content).to eq(before)
    end
  end
end
