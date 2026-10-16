# frozen_string_literal: true

require "rails_helper"

# What is hashed is what a reader gets. These examples hold that line: the bytes
# come from the endpoint named in the DID document, unchanged and
# uncanonicalised, and nothing in here raises -- a commitment that cannot be
# written leaves the passport "pending" instead of failing a write the custodian
# has already accepted (docs/Integrity.md section 6).
RSpec.describe PayloadCommitment do
  let(:oydid) { class_double("Oydid") }

  # Deliberately ugly: two spaces, keys out of order, a trailing newline. If any
  # step re-serialised the document, this body would not survive it.
  let(:delivered) { %({"dppStatus":"Active",  "digitalProductPassportId":"did:oyd:zABC"}\n) }

  before do
    allow(PayloadCommitment).to receive(:require).with("oydid").and_return(true)
    stub_const("Oydid", oydid)
    allow(oydid).to receive(:multi_hash).and_return(["zPAY", ""])
    allow(DidOyd).to receive(:service_endpoint)
      .and_return("https://dpp.go-data.at/dpp/v1/dppsByProductId/x")
  end

  def stub_delivery(status: 200, body: nil)
    requests = []
    allow(OutboundHttp).to receive(:perform) do |req, **|
      requests << req
      OutboundHttp::Response.new(code: status.to_s, body: body.nil? ? delivered : body,
                                 message: "stubbed", version: "2.0")
    end
    requests
  end

  def build_dpp(did_managed: true, storage_backend: "pod")
    Dpp.create!(
      dpp_id:               "did:oyd:zABC",
      product_id:           "https://dpp.oydapp.eu/01/09520123456788/21/000001",
      granularity:          "item",
      dpp_schema_version:   "EN 18223:2026",
      dpp_status:           "Active",
      economic_operator_id: "did:web:lumina.example",
      last_update:          Time.now.utc,
      storage_backend:      storage_backend,
      did_managed:          did_managed,
      did_doc_key:          (did_managed ? "z1S5doc" : nil),
      did_rev_key:          (did_managed ? "z1S5rev" : nil),
      content:              { "elements" => [] }
    )
  end

  describe "what gets hashed" do
    it "hashes the delivered bytes, exactly as they arrived" do
      stub_delivery
      allow(DidOyd).to receive(:update).and_return(nil)

      described_class.call(build_dpp)

      expect(oydid).to have_received(:multi_hash) do |message, options|
        expect(message).to eq(delivered.dup.force_encoding(Encoding::BINARY))
        expect(options[:digest]).to eq("sha2-256")
        expect(options[:encode]).to eq("base58btc")
      end
    end

    # Binary, because a reader hashes bytes. A body arriving as UTF-8 and the
    # same body as ASCII-8BIT have to give one value.
    it "hashes bytes, not characters" do
      stub_delivery(body: delivered.dup.force_encoding(Encoding::UTF_8))
      allow(DidOyd).to receive(:update).and_return(nil)

      described_class.call(build_dpp)

      expect(oydid).to have_received(:multi_hash) do |message, _options|
        expect(message.encoding).to eq(Encoding::BINARY)
      end
    end

    # The endpoint comes out of the DID document, and a consumer reaches it
    # without a token (prEN 18239 6.1). What is hashed is the full
    # representation (docs/Integrity.md section 4), which an EN 18222 read path
    # delivers only when asked for it.
    it "reads the full representation from the endpoint the DID document names, without a token" do
      requests = stub_delivery
      allow(DidOyd).to receive(:update).and_return(nil)

      described_class.call(build_dpp)

      expect(DidOyd).to have_received(:service_endpoint).with("did:oyd:zABC")
      expect(requests.last.path).to eq("/dpp/v1/dppsByProductId/x?representation=full")
      expect(requests.last["Authorization"]).to be_nil
    end

    # No second party to ask: this service is the custodian, so its own rendering
    # is what it delivers.
    it "hashes its own rendering for a passport it holds itself" do
      allow(OutboundHttp).to receive(:perform).and_raise("no HTTP call expected")
      allow(DidOyd).to receive(:update).and_return(nil)

      expect(described_class.call(build_dpp(storage_backend: "local")))
        .to eq(PayloadCommitment::COMMITTED)
    end
  end

  describe "Variante A — the service writes the entry" do
    it "commits the hash and records the state" do
      stub_delivery
      allow(DidOyd).to receive(:update).and_return(head: "did:oyd:zHEAD",
                                                  doc_key: "z1S5doc",
                                                  rev_key: "z1S5rev",
                                                  rev_log: { "op" => 1 })

      dpp = build_dpp
      expect(described_class.call(dpp)).to eq(PayloadCommitment::COMMITTED)

      dpp.reload
      expect(dpp.payload_hash).to eq("zPAY")
      expect(dpp.did_commit_state).to eq(PayloadCommitment::COMMITTED)
    end

    # An update mints a new identifier. It is the head of the log -- the passport
    # keeps the identifier the carrier bears and the registry holds.
    it "records the new identifier as the head and leaves dpp_id alone" do
      stub_delivery
      allow(DidOyd).to receive(:update).and_return(head: "did:oyd:zHEAD",
                                                  doc_key: "z1S5doc",
                                                  rev_key: "z1S5rev",
                                                  rev_log: nil)

      dpp = build_dpp
      described_class.call(dpp)

      expect(dpp.reload.did_head).to eq("did:oyd:zHEAD")
      expect(dpp.dpp_id).to eq("did:oyd:zABC")
    end

    # oydid generates a fresh pair whenever the options do not pin it. A passport
    # whose stored keys no longer match its document can never be updated or
    # revoked again, so whatever comes back is stored.
    it "stores the key material the update hands back" do
      stub_delivery
      allow(DidOyd).to receive(:update).and_return(head: "did:oyd:zHEAD",
                                                  doc_key: "zNEWdoc",
                                                  rev_key: "zNEWrev",
                                                  rev_log: { "op" => 1, "ts" => 2 })

      dpp = build_dpp
      described_class.call(dpp)

      dpp.reload
      expect(dpp.did_doc_key).to eq("zNEWdoc")
      expect(dpp.did_rev_key).to eq("zNEWrev")
      # As JSON: KeyVault stores strings, and Hash#to_s would leave Ruby inspect
      # syntax in the column.
      expect(dpp.did_rev_log).to eq('{"op":1,"ts":2}')
    end

    it "treats a document that already carries the hash as committed" do
      stub_delivery
      allow(DidOyd).to receive(:update).and_return(nil)

      dpp = build_dpp
      expect(described_class.call(dpp)).to eq(PayloadCommitment::COMMITTED)
      expect(dpp.reload.payload_hash).to eq("zPAY")
    end
  end

  describe "when the commitment cannot be written" do
    # Availability: the write was already accepted by the custodian. Refusing
    # here would undo nothing and report a failure for work that succeeded.
    it "leaves the passport pending when the VDR refuses, and does not raise" do
      stub_delivery
      allow(DidOyd).to receive(:update).and_raise(DidOyd::DidError, "public key already controls an active DID")

      dpp = build_dpp
      expect(described_class.call(dpp)).to eq(PayloadCommitment::PENDING)

      dpp.reload
      expect(dpp.payload_hash).to eq("zPAY")
      expect(dpp.did_commit_state).to eq(PayloadCommitment::PENDING)
    end

    it "records no hash when the custodian does not answer with the payload" do
      stub_delivery(status: 502)
      allow(DidOyd).to receive(:update)

      dpp = build_dpp
      expect(described_class.call(dpp)).to eq(PayloadCommitment::PENDING)

      expect(dpp.reload.payload_hash).to be_nil
      expect(DidOyd).not_to have_received(:update)
    end

    it "survives an unreachable custodian" do
      allow(OutboundHttp).to receive(:perform)
        .and_raise(OutboundHttp::ConnectionError, "HTTPX::ResolveError: getaddrinfo")
      allow(DidOyd).to receive(:update)

      expect(described_class.call(build_dpp)).to eq(PayloadCommitment::PENDING)
    end

    it "survives a DID that no longer resolves" do
      allow(DidOyd).to receive(:service_endpoint).and_raise(DidOyd::DidError, "does not resolve")
      allow(DidOyd).to receive(:update)

      expect(described_class.call(build_dpp)).to eq(PayloadCommitment::PENDING)
    end
  end

  # The read side of variant B. The holder signs the entry, so the only thing the
  # service can do is look -- and looking costs a DID resolution, which is why it
  # is throttled.
  describe ".refresh" do
    def pending_dpp(payload_hash: "zPAY", checked_at: nil)
      dpp = build_dpp(did_managed: false)
      dpp.update_columns(did_commit_state: PayloadCommitment::PENDING,
                         payload_hash: payload_hash,
                         payload_checked_at: checked_at)
      dpp.reload
    end

    def document_with(hash)
      content = { "service" => [{ "type" => "DigitalProductPassport",
                                  "serviceEndpoint" => "https://pod.example/x" }] }
      content["service"].first["payloadHash"] = hash if hash
      allow(DidOyd).to receive(:document_content).and_return(content)
    end

    it "sets committed once the document attests the payload the service delivered" do
      document_with("zPAY")
      dpp = pending_dpp

      expect(described_class.refresh(dpp)).to eq(PayloadCommitment::COMMITTED)
      expect(dpp.reload.did_commit_state).to eq(PayloadCommitment::COMMITTED)
    end

    # Not a failure of the commitment but of its currency: the holder attested
    # some other payload. A reader has to be told rather than left to find out.
    it "reports stale when the document attests a different payload" do
      document_with("zOLD")
      dpp = pending_dpp

      expect(described_class.refresh(dpp)).to eq(PayloadCommitment::STALE)
    end

    it "stays pending while the document carries no commitment" do
      document_with(nil)
      dpp = pending_dpp

      expect(described_class.refresh(dpp)).to eq(PayloadCommitment::PENDING)
    end

    it "stays pending and does not raise when the DID no longer resolves" do
      allow(DidOyd).to receive(:document_content).and_raise(DidOyd::DidError, "does not resolve")
      dpp = pending_dpp

      expect(described_class.refresh(dpp)).to eq(PayloadCommitment::PENDING)
    end

    # The throttle has to hold after a failure too, otherwise an unresolvable DID
    # is the most expensive passport in the database.
    it "records the check time even when nothing changed" do
      allow(DidOyd).to receive(:document_content).and_raise(DidOyd::DidError, "boom")
      dpp = pending_dpp

      described_class.refresh(dpp)

      expect(dpp.reload.payload_checked_at).to be_within(5).of(Time.now.utc)
    end

    it "does not resolve again inside the interval" do
      document_with("zPAY")
      dpp = pending_dpp(checked_at: 5.seconds.ago)

      expect(described_class.refresh(dpp)).to eq(PayloadCommitment::PENDING)
      expect(DidOyd).not_to have_received(:document_content)
    end

    it "resolves again once the interval has passed" do
      document_with("zPAY")
      dpp = pending_dpp(checked_at: (PayloadCommitment::RECHECK_INTERVAL + 10).seconds.ago)

      expect(described_class.refresh(dpp)).to eq(PayloadCommitment::COMMITTED)
    end

    it "leaves a state that is not pending alone" do
      allow(DidOyd).to receive(:document_content)
      dpp = build_dpp
      dpp.update_columns(did_commit_state: PayloadCommitment::COMMITTED, payload_hash: "zPAY")

      expect(described_class.refresh(dpp.reload)).to eq(PayloadCommitment::COMMITTED)
      expect(DidOyd).not_to have_received(:document_content)
    end

    it "does nothing for a passport that is not identified by a did:oyd" do
      allow(DidOyd).to receive(:document_content)
      dpp = pending_dpp
      dpp.update_column(:dpp_id, "https://dpp.lumina.example/01/09520123456788/8546")

      expect(described_class.refresh(dpp.reload)).to eq(PayloadCommitment::PENDING)
      expect(DidOyd).not_to have_received(:document_content)
    end

    it "does nothing when no hash has been recorded to compare against" do
      allow(DidOyd).to receive(:document_content)
      dpp = pending_dpp(payload_hash: nil)

      expect(described_class.refresh(dpp)).to eq(PayloadCommitment::PENDING)
      expect(DidOyd).not_to have_received(:document_content)
    end
  end

  # An https identifier has no log to write into. Not a degenerate case: it is
  # what every passport looked like before did:oyd, and EN 18223:2026 Table 1
  # does not require a DID.
  describe "a passport that is not identified by a did:oyd" do
    it "does nothing at all" do
      allow(OutboundHttp).to receive(:perform).and_raise("no HTTP call expected")
      allow(DidOyd).to receive(:update)

      dpp = build_dpp
      dpp.update_column(:dpp_id, "https://dpp.lumina.example/01/09520123456788/8546")

      expect(described_class.call(dpp.reload)).to be_nil
      expect(dpp.reload.did_commit_state).to be_nil
      expect(DidOyd).not_to have_received(:update)
    end
  end

  # Variante B: the holder has the document key, so the service can only report
  # which hash is expected -- section 6, point 2.
  describe "Variante B — the holder writes the entry" do
    it "records the expected hash and stays pending" do
      stub_delivery
      allow(DidOyd).to receive(:update)

      dpp = build_dpp(did_managed: false)
      expect(described_class.call(dpp)).to eq(PayloadCommitment::PENDING)

      dpp.reload
      expect(dpp.payload_hash).to eq("zPAY")
      expect(dpp.did_commit_state).to eq(PayloadCommitment::PENDING)
      expect(DidOyd).not_to have_received(:update)
    end
  end
end
