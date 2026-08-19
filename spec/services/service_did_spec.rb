# frozen_string_literal: true

require "rails_helper"
require "oydid"

# docs/Delegation.md §3 and §6: the identity this deployment signs with when it
# acts as a client at a hosting pod.
RSpec.describe ServiceDid do
  let(:did)      { "did:oyd:zQmServiceIdentityForTests" }
  let(:seed)     { Digest::SHA256.digest("service-did-spec") }
  let(:multibase) { "z1S5ThisIsNotDecodedInThisSpec" }

  # A real documentKey decodes to 35 bytes: a three-byte multicodec prefix
  # (00 13 20) and the 32-byte seed. Decoding itself is oydid's job, so it is
  # stubbed here — what this spec pins down is that we take the *last* 32 bytes
  # and never the first.
  def stub_decode(bytes)
    allow(Oydid).to receive(:multi_decode).with(multibase).and_return([bytes, nil])
  end

  def with_env(service_did: did, doc_key: multibase)
    allow(ENV).to receive(:[]).and_call_original
    allow(ENV).to receive(:fetch).and_call_original
    allow(ENV).to receive(:[]).with("DPP_SERVICE_DID").and_return(service_did)
    allow(ENV).to receive(:[]).with("DPP_SERVICE_DOC_KEY").and_return(doc_key)
    allow(ENV).to receive(:fetch).with("DPP_SERVICE_DOC_KEY").and_return(doc_key)
  end

  before { described_class.reset! }
  after  { described_class.reset! }

  describe ".configured?" do
    it "is false without the environment" do
      with_env(service_did: nil, doc_key: nil)

      expect(described_class).not_to be_configured
    end

    it "needs both the DID and the key" do
      with_env(doc_key: nil)

      expect(described_class).not_to be_configured
    end
  end

  describe ".signing_key" do
    it "takes the last 32 bytes, past the multicodec prefix" do
      with_env
      stub_decode("\x00\x13\x20".b + seed)

      expect(described_class.signing_key.to_bytes).to eq(seed)
    end

    it "is memoised, so the key is decoded once per process" do
      with_env
      stub_decode("\x00\x13\x20".b + seed)

      2.times { described_class.signing_key }

      expect(Oydid).to have_received(:multi_decode).once
    end

    it "refuses to run without configuration instead of signing with something else" do
      with_env(service_did: nil, doc_key: nil)

      expect { described_class.signing_key }
        .to raise_error(described_class::NotConfigured, /DPP_SERVICE_DID/)
    end

    it "reports a key that is too short rather than truncating it" do
      with_env
      stub_decode("\x00\x13\x20".b + "tooshort")

      expect { described_class.signing_key }
        .to raise_error(described_class::NotConfigured, /not a decodable multibase key/)
    end

    it "turns a decoding failure into NotConfigured" do
      with_env
      allow(Oydid).to receive(:multi_decode).with(multibase).and_raise(ArgumentError, "bad base58")

      expect { described_class.signing_key }
        .to raise_error(described_class::NotConfigured, /cannot be read/)
    end
  end

  describe ".discovery_document" do
    it "carries the DID and the audience, and nothing else" do
      with_env
      allow(DidTokenVerifier).to receive(:audience).and_return("https://dpp-service.example")

      expect(described_class.discovery_document)
        .to eq("did" => did, "audience" => "https://dpp-service.example")
    end
  end

  describe ".consistent?" do
    before do
      with_env
      stub_decode("\x00\x13\x20".b + seed)
    end

    it "is true when the configured key belongs to the configured DID" do
      allow(DidTokenVerifier).to receive(:public_key_for)
        .with(did).and_return(described_class.verify_key)

      expect(described_class).to be_consistent
    end

    it "is false when the DID resolves to a different key" do
      other = Ed25519::SigningKey.generate.verify_key
      allow(DidTokenVerifier).to receive(:public_key_for).with(did).and_return(other)

      expect(described_class).not_to be_consistent
    end

    it "is false when the DID does not resolve at all" do
      allow(DidTokenVerifier).to receive(:public_key_for).with(did).and_return(nil)

      expect(described_class).not_to be_consistent
    end
  end
end
