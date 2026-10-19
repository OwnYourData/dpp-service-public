# frozen_string_literal: true

require "rails_helper"
require "digest"
require "ed25519"
require_relative "../support/fake_pod"

# Whether the custodian has entered this service as reader of a collection,
# asked under the read grant and kept for a while (ReaderAdmission).
RSpec.describe ReaderAdmission do
  let(:base_url) { "https://dpp-staging.go-data.at" }
  let(:pod)      { FakePod.new(base_url) }
  let(:reader) do
    instance_double(ReaderDid, did: "did:oyd:zQmAdmissionReader", pod: base_url,
                               signing_key: Ed25519::SigningKey.new(Digest::SHA256.digest("admission/reader")))
  end
  let(:now) { Time.utc(2026, 10, 18, 12) }

  before do
    PodStorage.reset_token_cache!
    allow(ReaderDid).to receive(:for_pod).with(base_url).and_return(reader)
    allow(OutboundHttp).to receive(:perform) do |req, **|
      status, body = pod.call(req)
      OutboundHttp::Response.new(code: status.to_s, body: JSON.generate(body), message: "stubbed", version: "2.0")
    end
  end

  it "says entered when the custodian issues a token under the read grant for the collection" do
    pod.readers << reader.did

    expect(described_class.check(base_url, "36", now: now)).to eq(:entered)
    expect(pod.grants.map { |claims| claims["collections"] }).to eq([["36"]])
  end

  it "says not entered when the custodian answers the read grant with invalid_grant" do
    expect(described_class.check(base_url, "36", now: now)).to eq(:not_entered)
  end

  it "keeps an entered reader for ADMITTED_TTL, then asks again" do
    pod.readers << reader.did
    described_class.check(base_url, "36", now: now)
    PodStorage.reset_token_cache!
    pod.readers.clear

    expect(described_class.check(base_url, "36", now: now + described_class::ADMITTED_TTL - 1)).to eq(:entered)
    expect(pod.grants.size).to eq(1)
    expect(described_class.check(base_url, "36", now: now + described_class::ADMITTED_TTL)).to eq(:not_entered)
    expect(pod.grants.size).to eq(2)
  end

  it "keeps a missing reader for REFUSED_TTL only" do
    described_class.check(base_url, "36", now: now)
    pod.readers << reader.did

    expect(described_class.check(base_url, "36", now: now + described_class::REFUSED_TTL - 1)).to eq(:not_entered)
    expect(described_class.check(base_url, "36", now: now + described_class::REFUSED_TTL)).to eq(:entered)
    expect(described_class::REFUSED_TTL).to be < described_class::ADMITTED_TTL
  end

  it "keeps the answer per collection" do
    pod.collection_readers["5"] << reader.did

    expect(described_class.check(base_url, "4", now: now)).to eq(:not_entered)
    expect(described_class.check(base_url, "5", now: now)).to eq(:entered)
  end

  it "raises when the custodian cannot be asked, and keeps nothing" do
    pod.unreachable = true

    expect { described_class.check(base_url, "36", now: now) }
      .to raise_error(PodStorage::Error, /could not be checked .*unreachable.*nothing was written/)

    pod.unreachable = false
    pod.readers << reader.did
    expect(described_class.check(base_url, "36", now: now)).to eq(:entered)
  end

  it "says so without asking when no reader DID is configured for the pod" do
    allow(ReaderDid).to receive(:for_pod).with(base_url).and_return(nil)

    expect(described_class.check(base_url, "36", now: now)).to eq(:no_reader)
    expect(pod.log).to be_empty
  end
end
