# frozen_string_literal: true

require "rails_helper"

# Changing the custodian. The claim the paper makes is that this costs a
# delegation, a log entry and a DNS record -- and no reprint. The part that
# happens inside this service is the first of those: read the document from the
# custodian that still holds it, write it to the one the new mandate names, and
# repoint the passport.
#
# Both pods are stubbed; what is checked here is the wiring, not the HTTP layer.
RSpec.describe "Changing the custodian", type: :request do
  let(:token) do
    "Bearer #{JWT.encode({ sub: 'did:oyd:zQmPPwHJK1NHBz3BS89StWsfrH4pzkyqwJiK94zVj25wXUS',
                           scope: 'dpp:write' }, nil, 'none')}"
  end

  let(:url_a) { "https://dpp.go-data.at" }
  let(:url_b) { "https://dpp.data-vault.eu" }
  let(:delegation_a) { "eyJhbGciOiJFZERTQSJ9.YQ.c2ln" }
  let(:delegation_b) { "eyJhbGciOiJFZERTQSJ9.Yg.c2ln" }

  let(:product_id) { "https://dpp.oydapp.eu/01/09520123456791/21/000123" }
  let(:minted) do
    { did: "did:oyd:zPODhash123456", doc_key: "doc-secret", rev_key: "rev-secret", rev_log: "rev-log" }
  end

  let(:document) do
    { "ProductID" => product_id,
      "Granularity" => "item",
      "DPPSchemaVersion" => "prEN 18223:2025",
      "EconomicOperatorID" => "did:oyd:zQmPPwHJK1NHBz3BS89StWsfrH4pzkyqwJiK94zVj25wXUS" }
  end

  # A stubbed custodian that remembers what was written to it.
  def custodian(base_url, collection_id, delegation, object_id)
    fake = instance_double(PodStorage,
                           base_url: base_url,
                           collection_id: collection_id,
                           storage_delegation: delegation,
                           reachable!: true)
    store = {}
    allow(fake).to receive(:ensure_covers!).and_return(true)
    allow(fake).to receive(:create_object).and_return(object_id)
    allow(fake).to receive(:write_payload) { |_id, doc| store[:doc] = doc; true }
    allow(fake).to receive(:read_payload) { store[:doc] || {} }
    allow(fake).to receive(:delete_object).and_return(true)
    fake
  end

  let(:pod_a) { custodian(url_a, "4", delegation_a, "obj-a") }
  let(:pod_b) { custodian(url_b, "9", delegation_b, "obj-b") }

  let(:headers_a) do
    { "Content-Type" => "application/json",
      "Authorization" => token,
      "X-DPP-Storage" => { base_url: url_a, collection_id: "4",
                           delegation: delegation_a }.to_json }
  end
  let(:headers_b) { headers_a.merge("X-DPP-Storage" => { base_url: url_b, collection_id: "9", delegation: delegation_b }.to_json) }

  before do
    allow(DidOyd).to receive(:mint).and_return(minted)
    allow(PodStorage).to receive(:from_header).and_return(pod_a, pod_b)
    allow(PodStorage).to receive(:for).and_return(pod_a)

    post "/dpp/v1/dpps", params: document.to_json, headers: headers_a
    expect(response).to have_http_status(:created)
  end

  let(:dpp_id) { minted[:did] }

  describe "the move itself" do
    it "writes the document to the new custodian and repoints the passport" do
      post "/dpp/v1/dpps/#{CGI.escape(dpp_id)}/custody", headers: headers_b

      expect(response).to have_http_status(:ok)
      expect(pod_b).to have_received(:create_object)
      expect(pod_b).to have_received(:write_payload)
        .with("obj-b", hash_including("ProductID" => product_id))

      dpp = Dpp.find(dpp_id)
      expect(dpp.storage_base_url).to eq(url_b)
      expect(dpp.storage_collection_id).to eq("9")
      expect(dpp.storage_delegation).to eq(delegation_b)
      expect(dpp.storage_object_id).to eq("obj-b")
    end

    # The identifier is what the carrier bears. If it changed here, every
    # printed carrier would be dead -- which is precisely the property under
    # test (prEN 18219, 4.6.2 (3)).
    it "leaves the identifier and the product key untouched" do
      before_move = Dpp.find(dpp_id)

      post "/dpp/v1/dpps/#{CGI.escape(dpp_id)}/custody", headers: headers_b

      after_move = Dpp.find(dpp_id)
      expect(after_move.dpp_id).to eq(before_move.dpp_id)
      expect(after_move.product_id).to eq(before_move.product_id)
      expect(after_move.product_key).to eq(before_move.product_key)
    end

    it "keeps no copy of the document in the local database" do
      post "/dpp/v1/dpps/#{CGI.escape(dpp_id)}/custody", headers: headers_b

      row = Dpp.connection.select_one(
        "SELECT content, storage_backend FROM dpps WHERE dpp_id = '#{dpp_id}'"
      )
      expect(row["storage_backend"]).to eq("pod")
      expect(row["content"].to_s).not_to include("09520123456791")
    end
  end

  describe "what happens to the previous custodian" do
    it "leaves it serving by default" do
      post "/dpp/v1/dpps/#{CGI.escape(dpp_id)}/custody", headers: headers_b

      expect(pod_a).not_to have_received(:delete_object)
    end

    it "releases it only when asked, and then under its own mandate" do
      post "/dpp/v1/dpps/#{CGI.escape(dpp_id)}/custody?release_previous=true",
           headers: headers_b

      expect(response).to have_http_status(:ok)
      expect(pod_a).to have_received(:ensure_covers!).with("delete")
      expect(pod_a).to have_received(:delete_object).with("obj-a")
    end

    # The passport has already arrived at the new custodian. Undoing the move
    # because the old one refused to let go would leave it in limbo, which is
    # worse than leaving a copy behind.
    it "does not undo the move when the release fails" do
      allow(pod_a).to receive(:delete_object)
        .and_raise(PodStorage::Error.new("pod unreachable"))

      post "/dpp/v1/dpps/#{CGI.escape(dpp_id)}/custody?release_previous=true",
           headers: headers_b

      expect(response).to have_http_status(:ok)
      expect(Dpp.find(dpp_id).storage_base_url).to eq(url_b)
    end
  end

  describe "refusals" do
    it "refuses without a new mandate" do
      post "/dpp/v1/dpps/#{CGI.escape(dpp_id)}/custody",
           headers: headers_b.except("X-DPP-Storage")

      expect(response).to have_http_status(:bad_request)
      expect(Dpp.find(dpp_id).storage_base_url).to eq(url_a)
    end

    it "refuses to move a passport to where it already is" do
      allow(PodStorage).to receive(:from_header).and_return(pod_a)

      post "/dpp/v1/dpps/#{CGI.escape(dpp_id)}/custody", headers: headers_a

      expect(response).to have_http_status(:bad_request)
      expect(pod_a).to have_received(:create_object).once
    end

    # A mandate that does not permit writing must be refused before the
    # passport is repointed, not at the first write afterwards.
    it "refuses a mandate that does not cover creation" do
      allow(pod_b).to receive(:ensure_covers!).with("create")
        .and_raise(PodStorage::DelegationError.new("does not cover create",
                                                   status_code: "ClientForbidden"))

      post "/dpp/v1/dpps/#{CGI.escape(dpp_id)}/custody", headers: headers_b

      expect(response).to have_http_status(:forbidden)
      expect(Dpp.find(dpp_id).storage_base_url).to eq(url_a)
    end

    it "refuses when the new custodian cannot be reached" do
      allow(pod_b).to receive(:reachable!)
        .and_raise(PodStorage::Error.new("pod unreachable"))

      post "/dpp/v1/dpps/#{CGI.escape(dpp_id)}/custody", headers: headers_b

      expect(Dpp.find(dpp_id).storage_base_url).to eq(url_a)
    end
  end
end
