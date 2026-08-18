# frozen_string_literal: true

require "rails_helper"

# Stufe S2: die DPP-Inhalte liegen nicht lokal, sondern in einem vom
# Datenintermediär verwalteten Hosting-Pod. Der Pod selbst ist gestubbt — hier
# wird die Verdrahtung im DPP Service geprüft, nicht die HTTP-Schicht
# (die deckt spec/services/pod_storage_spec.rb ab).
RSpec.describe "CreateDPP with a hosting pod (S2)", type: :request do
  let(:token) { "Bearer #{JWT.encode({ sub: 'did:oyd:zQmPPwHJK1NHBz3BS89StWsfrH4pzkyqwJiK94zVj25wXUS', scope: 'dpp:write' }, nil, 'none')}" }
  let(:base_url) { "https://dpp.go-data.at" }

  let(:storage_jwt) do
    JWT.encode({ base_url: base_url, collection_id: "1",
                 client_id: "pod-client", client_secret: "pod-secret" }, nil, "none")
  end

  let(:headers) do
    { "Content-Type" => "application/json",
      "Authorization" => token,
      "X-DPP-Storage" => storage_jwt }
  end
  let(:local_headers) { headers.except("X-DPP-Storage") }

  let(:product_id) { "https://id.lumina.example/01/09520123456788" }
  let(:minted) do
    { did: "did:oyd:zPODhash123456", doc_key: "doc-secret", rev_key: "rev-secret", rev_log: "rev-log" }
  end

  let(:document) do
    { "ProductID" => product_id,
      "Granularity" => "model",
      "DPPSchemaVersion" => "prEN 18223:2025",
      "EconomicOperatorID" => "did:oyd:zQmPPwHJK1NHBz3BS89StWsfrH4pzkyqwJiK94zVj25wXUS" }
  end

  # Fake-Pod: merkt sich das zuletzt geschriebene Dokument.
  let(:pod) do
    fake = instance_double(PodStorage,
                           base_url: base_url,
                           collection_id: "1",
                           credentials_json: { base_url: base_url, collection_id: "1",
                                               client_id: "pod-client",
                                               client_secret: "pod-secret" }.to_json,
                           reachable!: true)
    allow(fake).to receive(:create_object).and_return("4711")
    allow(fake).to receive(:write_payload) { |_id, doc| @written = doc; true }
    allow(fake).to receive(:read_payload) { @written || {} }
    allow(fake).to receive(:delete_object).and_return(true)
    fake
  end

  before do
    allow(PodStorage).to receive(:from_jwt).and_return(pod)
    allow(PodStorage).to receive(:for).and_return(pod)
    allow(DidOyd).to receive(:mint).and_return(minted)
  end

  describe "creating" do
    it "mints the DID with the pod as serviceEndpoint base" do
      post "/dpp/v1/dpps", params: document.to_json, headers: headers

      expect(response).to have_http_status(:created)
      expect(DidOyd).to have_received(:mint).with(product_id, endpoint_base: base_url)
    end

    it "writes the card and the document into the pod" do
      post "/dpp/v1/dpps", params: document.to_json, headers: headers

      expect(pod).to have_received(:create_object)
      expect(pod).to have_received(:write_payload).with("4711", hash_including("ProductID" => product_id))
      expect(Dpp.find(minted[:did]).storage_object_id).to eq("4711")
    end

    it "keeps no copy of the document in the local database" do
      post "/dpp/v1/dpps", params: document.to_json, headers: headers

      row = Dpp.connection.select_one("SELECT content, storage_backend FROM dpps WHERE dpp_id = '#{minted[:did]}'")
      expect(row["storage_backend"]).to eq("pod")
      expect(row["content"].to_s).not_to include("lumina.example")
    end

    it "serves the UPI from the pod, not from the service's own short-link host" do
      post "/dpp/v1/dpps", params: document.to_json, headers: headers

      upi = JSON.parse(response.body)["UPI"]
      expect(upi).to start_with("#{base_url}/p/")
      expect(upi.length).to be <= 50
    end

    it "stores the pod credentials encrypted and never returns them" do
      post "/dpp/v1/dpps", params: document.to_json, headers: headers

      dpp = Dpp.find(minted[:did])
      expect(dpp.storage_credentials_enc).to be_present
      expect(dpp.storage_credentials_enc).not_to include("pod-secret")
      expect(KeyVault.decrypt(dpp.storage_credentials_enc)).to include("pod-secret")
      expect(response.body).not_to include("pod-secret")
      expect(response.body).not_to include("storage_credentials")
    end

    it "stores locally when no storage token is supplied" do
      post "/dpp/v1/dpps", params: document.to_json, headers: local_headers

      expect(response).to have_http_status(:created)
      expect(Dpp.find(minted[:did]).pod?).to be(false)
      expect(DidOyd).to have_received(:mint).with(product_id)
    end
  end

  describe "validation of the storage token" do
    before { allow(PodStorage).to receive(:from_jwt).and_call_original }

    def post_with(payload)
      post "/dpp/v1/dpps", params: document.to_json,
           headers: headers.merge("X-DPP-Storage" => JWT.encode(payload, nil, "none"))
    end

    let(:valid) do
      { base_url: base_url, collection_id: "1", client_id: "c", client_secret: "s" }
    end

    it "rejects a base_url that would break the Registry's 50-character limit" do
      post_with(valid.merge(base_url: "https://a-rather-long-pod-hostname.example.org"))

      expect(response).to have_http_status(:bad_request)
      expect(JSON.parse(response.body)["message"].first["text"]).to include("50-character")
    end

    it "rejects a base_url that is not https (prEN 18216 §6.2)" do
      post_with(valid.merge(base_url: "http://dpp.go-data.at"))
      expect(response).to have_http_status(:bad_request)
    end

    it "rejects an incomplete storage token" do
      post_with(valid.except(:client_secret))
      expect(response).to have_http_status(:bad_request)
    end

    it "rejects a malformed storage token" do
      post "/dpp/v1/dpps", params: document.to_json,
           headers: headers.merge("X-DPP-Storage" => "not-a-jwt")
      expect(response).to have_http_status(:bad_request)
    end
  end

  describe "when the pod is unreachable" do
    it "reports a bad gateway and mints nothing" do
      allow(pod).to receive(:reachable!).and_raise(PodStorage::Error, "Pod unreachable")

      post "/dpp/v1/dpps", params: document.to_json, headers: headers

      expect(response).to have_http_status(:bad_gateway)
      expect(DidOyd).not_to have_received(:mint)
      expect(Dpp.exists?(minted[:did])).to be(false)
    end

    it "rolls back the passport and revokes the DID if the write fails" do
      allow(pod).to receive(:write_payload).and_raise(PodStorage::Error, "Pod write failed")
      allow(DidOyd).to receive(:revoke)

      post "/dpp/v1/dpps", params: document.to_json, headers: headers

      expect(response).to have_http_status(:bad_gateway)
      expect(Dpp.exists?(minted[:did])).to be(false)
      expect(DidOyd).to have_received(:revoke)
        .with(minted[:did], doc_key: "doc-secret", rev_key: "rev-secret")
    end
  end

  describe "reading, updating and deleting" do
    let(:encoded) { CGI.escape(minted[:did]) }

    before { post "/dpp/v1/dpps", params: document.to_json, headers: headers }

    it "reads the document back from the pod" do
      get "/dpp/v1/dpps/#{encoded}"

      expect(response).to have_http_status(:ok)
      expect(JSON.parse(response.body)["ProductID"]).to eq(product_id)
      expect(pod).to have_received(:read_payload).at_least(:once)
    end

    it "writes an update to the pod and does not archive locally" do
      patch "/dpp/v1/dpps/#{encoded}",
            params: { "FacilityID" => "https://id.lumina.example/414/0952012345002" }.to_json,
            headers: { "Content-Type" => "application/merge-patch+json", "Authorization" => token }

      expect(response).to have_http_status(:ok)
      expect(JSON.parse(response.body)["FacilityID"]).to eq("https://id.lumina.example/414/0952012345002")
      # prEN 18221 is satisfied by the pod's own history — no second copy here.
      expect(DppVersion.count).to eq(0)
      expect(pod).to have_received(:write_payload).twice
    end

    it "patches a single data element through the pod" do
      patch "/dpp/v1/dpps/#{encoded}",
            params: { "dataElementCollections" => [
              { "ElementId" => "EnergyPerformance",
                "DataElements" => [{ "ElementId" => "LuminousFlux", "Value" => 806 }] }
            ] }.to_json,
            headers: { "Content-Type" => "application/merge-patch+json", "Authorization" => token }
      expect(response).to have_http_status(:ok)

      patch "/dpp/v1/dpps/#{encoded}/elements/dataElementCollections/EnergyPerformance/DataElements/LuminousFlux",
            params: { "Value" => 900 }.to_json,
            headers: { "Content-Type" => "application/merge-patch+json", "Authorization" => token }

      expect(response).to have_http_status(:ok)
      expect(JSON.parse(response.body)["Value"]).to eq(900)
    end

    it "archives the final state in the pod and removes the object on delete" do
      allow(DidOyd).to receive(:revoke)

      delete "/dpp/v1/dpps/#{encoded}", headers: { "Authorization" => token }

      expect(response).to have_http_status(:no_content)
      expect(@written["DPPStatus"]).to eq("Archived")
      expect(pod).to have_received(:delete_object).with("4711")
      expect(Dpp.exists?(minted[:did])).to be(false)
    end

    it "delegates ReadDPPVersionByProductIdAndDate to the pod" do
      allow(pod).to receive(:version_at).and_return({ "DPPStatus" => "Active", "FacilityID" => "F-1" })

      get "/dpp/v1/dppsByProductIdAndDate/#{CGI.escape(product_id)}?date=2026-08-12T12:00:00Z"

      expect(response).to have_http_status(:ok)
      expect(JSON.parse(response.body)["FacilityID"]).to eq("F-1")
      expect(pod).to have_received(:version_at)
    end

    it "returns 404 when the pod has no version for that date" do
      allow(pod).to receive(:version_at).and_return(nil)

      get "/dpp/v1/dppsByProductIdAndDate/#{CGI.escape(product_id)}?date=2020-01-01T00:00:00Z"

      expect(response).to have_http_status(:not_found)
    end
  end
end
