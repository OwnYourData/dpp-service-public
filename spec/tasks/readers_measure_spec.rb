# frozen_string_literal: true

require "rails_helper"
require "rake"
require "digest"
require "ed25519"
require_relative "../support/fake_pod"

# The measurement a person runs against a real custodian: what it prints, and
# what it never prints.
RSpec.describe "dpp:readers:measure" do
  let(:base_url) { "https://dpp-staging.go-data.at" }
  let(:pod)      { FakePod.new(base_url) }
  let(:key)      { Ed25519::SigningKey.new(Digest::SHA256.digest("measure-spec/reader")) }
  let(:reader)   { instance_double(ReaderDid, did: "did:oyd:zQmReader", pod: base_url, signing_key: key) }
  let(:dpp_id)   { "did:oyd:zQmMeasured" }

  let(:controlled_payload) do
    PassportSplit.controlled_payload({ "digitalProductPassportId" => dpp_id,
                                       "elements" => [{ "elementId" => "Serial", "value" => "SECRET-42" }] })
  end
  let(:public_payload) do
    PassportSplit.public_payload({ "digitalProductPassportId" => dpp_id, "elements" => [] }, controlled_payload)
  end

  before(:all) do
    Rails.application.load_tasks if Rake::Task.tasks.none? { |t| t.name == "dpp:readers:measure" }
  end

  before do
    PodStorage.reset_token_cache!
    Rake::Task["dpp:readers:measure"].reenable
    allow(ReaderDid).to receive(:for_pod).with(base_url).and_return(reader)
    allow(OutboundHttp).to receive(:perform) do |req, **|
      status, body = pod.call(req)
      OutboundHttp::Response.new(code: status.to_s, body: JSON.generate(body), message: "stubbed", version: "2.0")
    end
    public_card = pod.put_card(FakePod::PUBLIC, dpp_id, "https://x/01/2", public_payload)
    controlled_card = pod.put_card(FakePod::CONTROLLED, dpp_id, "https://x/01/2", controlled_payload)
    Dpp.create!(dpp_id: dpp_id, product_id: "https://dpp.oydapp.eu/01/09520123456788/21/000999", granularity: "item",
                dpp_schema_version: "EN 18223:2026", dpp_status: "Active", economic_operator_id: "did:oyd:zQmOp",
                last_update: Time.now.utc, content: {}, storage_backend: "pod", storage_base_url: base_url,
                storage_collection_id: "60", storage_delegation: "x.y.z",
                storage_object_id: public_card.id, storage_controlled_object_id: controlled_card.id)
  end

  def run_task
    ENV["DPP"] = dpp_id
    output = StringIO.new
    $stdout = output
    Rake::Task["dpp:readers:measure"].invoke
    output.string
  ensure
    $stdout = STDOUT
    ENV.delete("DPP")
  end

  it "reports that the pod knows the reader, what it read, and that ControlledData matches" do
    pod.readers << reader.did
    out = run_task

    expect(out).to include("Pod kennt unseren Leser: ja", "scope=\"collection:60 act:read\"",
                           "kontrollierte Karte enthalten", "Passkennung passt",
                           "Attribute der kontrollierten Karte: Serial", "gleich der gespeicherten")
    expect(out).to match(/ControlledData .*: passt$/)
  end

  it "never prints a value, the grant or the token" do
    pod.readers << reader.did
    out = run_task

    expect(out).not_to include("SECRET-42", "read-token-", PodStorage::ProtectedReader.new(reader, "60").grant)
  end

  it "logs every read it makes under the read grant as made for the measurement" do
    pod.readers << reader.did
    run_task

    grant_reads = pod.headers.count { |method, _, auth| method == :get && auth.to_s.start_with?("DPoP read-token-") }
    logged = AccessEvent.where(event: "serviceRead")
    expect(logged.count).to eq(grant_reads)
    expect(logged.map(&:reason).uniq).to eq(["measure"])
    expect(logged.map(&:dpp_id).uniq).to eq([dpp_id])
  end

  it "says plainly when the pod does not know the reader" do
    out = run_task

    expect(out).to include("NotAdmitted", "Pod kennt unseren Leser: nein")
    expect(out).not_to include("GET /collection")
  end
end
