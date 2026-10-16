# frozen_string_literal: true

require "rails_helper"
require "oydid"

# The reader DIDs: one per pod, each different from the service DID and from
# every other reader, read from the environment and never shown.
RSpec.describe ReaderDid do
  let(:service_did) { "did:oyd:zQmServiceForReaderSpec" }
  let(:staging_did) { "did:oyd:zQmReaderStagingForSpec" }
  let(:production_did) { "did:oyd:zQmReaderProductionForSpec" }

  def key
    generated = Oydid.generate_private_key("", "ed25519-priv")
    generated.is_a?(Array) ? generated.first : generated
  end

  let(:staging_key)    { key }
  let(:production_key) { key }

  let(:env) do
    { "DPP_READERS" => "STAGING, PRODUCTION",
      "DPP_READER_STAGING_POD" => "https://dpp-staging.go-data.at",
      "DPP_READER_STAGING_DID" => staging_did,
      "DPP_READER_STAGING_DOC_KEY" => staging_key,
      "DPP_READER_PRODUCTION_POD" => "https://dpp.go-data.at/",
      "DPP_READER_PRODUCTION_DID" => production_did,
      "DPP_READER_PRODUCTION_DOC_KEY" => production_key }
  end

  before do
    described_class.reset!
    allow(ServiceDid).to receive(:did).and_return(service_did)
  end

  after { described_class.reset! }

  def problems_for(changed)
    described_class.load(env.merge(changed))
    []
  rescue described_class::ConfigError => e
    e.problems
  end

  describe ".load" do
    it "reads one reader per pod, with the base URL as the pod knows it" do
      readers = described_class.load(env)

      expect(readers.map { |r| [r.name, r.pod, r.did] }).to eq(
        [["STAGING", "https://dpp-staging.go-data.at", staging_did],
         ["PRODUCTION", "https://dpp.go-data.at", production_did]]
      )
    end

    it "decodes each key into a signing key of its own" do
      staging, production = described_class.load(env)

      expect(staging.signing_key).to be_a(Ed25519::SigningKey)
      expect(staging.signing_key.to_bytes).not_to eq(production.signing_key.to_bytes)
    end

    it "is empty when no reader is configured" do
      expect(described_class.load({})).to eq([])
    end

    it "refuses a reader DID that is the service DID" do
      expect(problems_for("DPP_READER_STAGING_DID" => service_did))
        .to include(/STAGING is the service DID/)
    end

    it "refuses the same DID for two pods" do
      expect(problems_for("DPP_READER_PRODUCTION_DID" => staging_did))
        .to include(/#{staging_did} is the reader of more than one pod/)
    end

    it "refuses two readers for one pod" do
      expect(problems_for("DPP_READER_PRODUCTION_POD" => "https://dpp-staging.go-data.at"))
        .to include(%r{https://dpp-staging.go-data.at has more than one reader})
    end

    {
      "a pod that is not https" => { "DPP_READER_STAGING_POD" => "http://dpp-staging.go-data.at" },
      "a pod with a query" => { "DPP_READER_STAGING_POD" => "https://dpp-staging.go-data.at?x=1" },
      "a missing DID" => { "DPP_READER_STAGING_DID" => "" },
      "a DID of another method" => { "DPP_READER_STAGING_DID" => "did:web:example.org" },
      "a missing key" => { "DPP_READER_STAGING_DOC_KEY" => "" },
      "a key that does not decode" => { "DPP_READER_STAGING_DOC_KEY" => "nope" },
      "a name that cannot be a variable" => { "DPP_READERS" => "staging" },
      "a name listed twice" => { "DPP_READERS" => "STAGING,STAGING" }
    }.each do |what, change|
      it "refuses #{what}" do
        expect(problems_for(change)).not_to be_empty
      end
    end

    it "collects every problem before refusing" do
      problems = problems_for("DPP_READER_STAGING_POD" => "http://x", "DPP_READER_PRODUCTION_DID" => "")

      expect(problems.size).to eq(2)
    end

    it "names the variable of a key that does not decode, and nothing of the key" do
      problems = problems_for("DPP_READER_STAGING_DOC_KEY" => "z1S5notakey")

      expect(problems.join).to include("DPP_READER_STAGING_DOC_KEY")
      expect(problems.join).not_to include("z1S5notakey")
    end
  end

  describe "choosing the reader for a passport" do
    before { stub_const("ENV", ENV.to_h.merge(env)) }

    it "takes the reader whose pod is the passport's storage base URL" do
      expect(described_class.for_pod("https://dpp.go-data.at").did).to eq(production_did)
      expect(described_class.for_pod("https://dpp-staging.go-data.at/").did).to eq(staging_did)
    end

    it "has no reader for any other pod" do
      expect(described_class.for_pod("https://dpp.data-vault.eu")).to be_nil
    end

    it "has no reader at all while the configuration is refused" do
      stub_const("ENV", ENV.to_h.merge("DPP_READER_STAGING_DID" => service_did))
      described_class.reset!

      expect(described_class.for_pod("https://dpp.go-data.at")).to be_nil
      expect(described_class.discovery_entries).to be_nil
    end
  end

  describe ".discovery_entries" do
    it "lists pod and DID of every reader, and nothing else" do
      stub_const("ENV", ENV.to_h.merge(env))

      expect(described_class.discovery_entries).to eq(
        [{ "pod" => "https://dpp-staging.go-data.at", "did" => staging_did },
         { "pod" => "https://dpp.go-data.at", "did" => production_did }]
      )
    end

    it "is nil, not an empty list, when no reader is configured" do
      stub_const("ENV", ENV.to_h.except("DPP_READERS"))

      expect(described_class.discovery_entries).to be_nil
    end
  end

  describe ".boot_check" do
    let(:logger) { instance_double(Logger, info: nil, error: nil) }

    it "logs which reader serves which pod" do
      stub_const("ENV", ENV.to_h.merge(env))

      described_class.boot_check(logger)

      expect(logger).to have_received(:info).with(/STAGING: #{staging_did} for https:\/\/dpp-staging.go-data.at/)
    end

    it "logs a refused configuration instead of stopping the service" do
      stub_const("ENV", ENV.to_h.merge(env, "DPP_READER_STAGING_DID" => service_did))

      expect(described_class.boot_check(logger)).to eq([])
      expect(logger).to have_received(:error).with(/no reader DID is published or used/)
    end
  end

  describe "#consistent?" do
    let(:reader) { described_class.load(env).first }

    it "is true when the DID resolves to the configured key" do
      allow(DidTokenVerifier).to receive(:public_key_for).with(staging_did)
                                                       .and_return(reader.signing_key.verify_key)

      expect(reader).to be_consistent
    end

    it "is false when it resolves to another key or not at all" do
      other = Ed25519::SigningKey.generate.verify_key
      allow(DidTokenVerifier).to receive(:public_key_for).with(staging_did).and_return(other)
      expect(reader).not_to be_consistent

      allow(DidTokenVerifier).to receive(:public_key_for).with(staging_did).and_return(nil)
      expect(reader).not_to be_consistent
    end
  end

  it "never shows its key, not even when inspected" do
    reader = described_class.load(env).first

    expect(reader.inspect).not_to include(staging_key)
    expect(reader.inspect).to include(staging_did)
  end
end
