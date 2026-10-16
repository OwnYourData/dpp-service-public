# frozen_string_literal: true

require "rails_helper"
require "digest"
require "ed25519"
require_relative "../support/fake_pod"

# This service as protected reader of a DPP hosting collection: the read grant
# it signs itself with the reader DID of the pod, the token it gets for it, and
# what it reads with that token. The custodian is a FakePod behind OutboundHttp.
RSpec.describe PodStorage::ProtectedReader do
  let(:base_url) { "https://dpp-staging.go-data.at" }
  let(:pod)      { FakePod.new(base_url) }
  let(:key)      { Ed25519::SigningKey.new(Digest::SHA256.digest("protected-reader-spec/reader")) }
  let(:did)      { "did:oyd:zQmReaderForSpec" }
  let(:reader)   { instance_double(ReaderDid, did: did, pod: base_url, signing_key: key) }
  let(:requests) { [] }

  subject(:protected_reader) { described_class.new(reader, "60") }

  def decode(jwt)
    jwt.split(".").first(2).map { |part| JSON.parse(Base64.urlsafe_decode64(part + ("=" * ((4 - (part.length % 4)) % 4)))) }
  end

  def token_requests = requests.select { |r| r.path == "/oauth/token" }

  def form_of(request) = URI.decode_www_form(request.body).to_h

  before do
    PodStorage.reset_token_cache!
    pod.readers << did
    allow(OutboundHttp).to receive(:perform) do |req, **|
      requests << req
      status, body = pod.call(req)
      OutboundHttp::Response.new(code: status.to_s, body: JSON.generate(body), message: "stubbed", version: "2.0")
    end
  end

  describe "the read grant" do
    let(:now) { Time.utc(2026, 10, 14, 10).to_i }

    it "names this service as reader and subject, the pod, one collection, and reading only" do
      header, claims = decode(protected_reader.grant(now: now))

      expect(header).to eq("alg" => "EdDSA", "typ" => "pod-read-delegation+jwt", "kid" => "#{did}#key-doc")
      expect(claims).to include("iss" => did, "sub" => did, "aud" => base_url, "collections" => ["60"],
                                "act" => ["read"], "purpose" => "espr_legal_access")
      expect(claims).not_to have_key("product_id")
    end

    it "runs 90 days from the start of its 30-day window and leaves at least 60 of them" do
      _, claims = decode(protected_reader.grant(now: now))

      expect(claims["exp"] - claims["iat"]).to eq(90 * 86_400)
      expect(claims["nbf"]).to eq(claims["iat"])
      expect(claims["iat"]).to be <= now
      expect(claims["exp"] - now).to be >= 60 * 86_400
    end

    it "is the same grant, byte for byte and under the same name, all through its window" do
      later = now + 3600
      expect(protected_reader.grant(now: later)).to eq(protected_reader.grant(now: now))
    end

    it "is signed anew, under a new name, in the next window" do
      _, first = decode(protected_reader.grant(now: now))
      _, second = decode(protected_reader.grant(now: now + (30 * 86_400)))

      expect(second["jti"]).not_to eq(first["jti"])
      expect(second["iat"]).to be > first["iat"]
    end

    it "verifies with the document key of the reader DID" do
      jwt = protected_reader.grant(now: now)
      signing_input, signature = jwt.rpartition(".").values_at(0, 2)

      expect(key.verify_key.verify(Base64.urlsafe_decode64(signature + ("=" * ((4 - (signature.length % 4)) % 4))),
                                   signing_input)).to be(true)
    end
  end

  describe "the token" do
    it "is fetched with the grant, a client assertion and a DPoP proof, all under the reader's key" do
      protected_reader.token

      form = form_of(token_requests.first)
      expect(form["grant_type"]).to eq("urn:ietf:params:oauth:grant-type:jwt-bearer")
      expect(decode(form["assertion"]).first["typ"]).to eq("pod-read-delegation+jwt")
      assertion_header, assertion = decode(form["client_assertion"])
      expect(assertion_header["kid"]).to eq("#{did}#key-doc")
      expect(assertion).to include("iss" => did, "sub" => did, "aud" => "#{base_url}/oauth/token")
      dpop_header, = decode(token_requests.first["DPoP"])
      expect(dpop_header["jwk"]).to eq(Delegation.jwk_for(key.verify_key))
    end

    it "is fetched once per pod and collection, not once per call" do
      protected_reader.token
      protected_reader.token
      described_class.new(reader, "60").token

      expect(token_requests.size).to eq(1)

      described_class.new(reader, "61").token
      expect(token_requests.size).to eq(2)
      expect(pod.grants.map { |claims| claims["collections"] }).to eq([["60"], ["61"]])
    end

    it "reports scope and lifetime, never the token" do
      protected_reader.token

      expect(protected_reader.last_grant_answer).to eq("scope" => "collection:60 act:read",
                                                       "expires_in" => 600, "token_type" => "DPoP")
    end

    it "is refused with invalid_grant, finally and with a message of its own, when the pod does not know the reader" do
      pod.readers.clear

      expect { protected_reader.token }
        .to raise_error(described_class::NotAdmitted, /does not accept this service as protected reader of collection 60/)
      expect { protected_reader.token }.to raise_error(described_class::NotAdmitted)
      expect(token_requests.size).to eq(2)
    end

    it "is not written to the log, nor is the grant" do
      log = StringIO.new
      allow(Rails).to receive(:logger).and_return(ActiveSupport::Logger.new(log))
      pod.readers.clear
      grant = protected_reader.grant

      expect { protected_reader.token }.to raise_error(described_class::NotAdmitted)
      expect(log.string).not_to include(grant)
      expect(log.string).to include("refused with 400 invalid_grant")
    end
  end

  describe "reading" do
    let(:dpp_id)  { "did:oyd:zQmPass" }
    let!(:public_card)     { pod.put_card(FakePod::PUBLIC, dpp_id, "https://x/01/1", { "elements" => [] }) }
    let!(:controlled_card) { pod.put_card(FakePod::CONTROLLED, dpp_id, "https://x/01/1", { "elements" => [{ "elementId" => "A" }] }) }

    it "reads the controlled card" do
      expect(protected_reader.read_object(controlled_card.id)).to eq("elements" => [{ "elementId" => "A" }])
    end

    it "lists the objects and reads index cards and meta, which a write token may not" do
      expect(protected_reader.object_ids).to contain_exactly(public_card.id, controlled_card.id)
      expect(protected_reader.card(controlled_card.id)["type"]).to eq(FakePod::CONTROLLED)
      expect(protected_reader.meta(controlled_card.id)).to have_key("updated-at")
    end

    it "finds the controlled card of a passport, the more recently changed of two" do
      older = pod.put_card(FakePod::CONTROLLED, dpp_id, "https://x/01/1", { "elements" => [] })
      older.updated_at = 0

      expect(protected_reader.locate_controlled_card(dpp_id)).to eq(controlled_card.id)
      expect(protected_reader.locate_controlled_card("did:oyd:zQmOther")).to be_nil
    end

    it "fetches one new token when the resource refuses the token, and goes on" do
      protected_reader.token
      pod.withdraw_read_tokens!

      expect(protected_reader.read_object(controlled_card.id)).to eq("elements" => [{ "elementId" => "A" }])
      expect(token_requests.size).to eq(2)
    end

    it "ends with invalid_grant when the reader has been removed meanwhile" do
      protected_reader.token
      pod.withdraw_read_tokens!
      pod.readers.clear

      expect { protected_reader.read_object(controlled_card.id) }.to raise_error(described_class::NotAdmitted)
      expect(token_requests.size).to eq(2)
    end
  end

  it "needs a reader DID for the pod" do
    allow(ReaderDid).to receive(:for_pod).with("https://dpp.go-data.at").and_return(nil)

    expect { described_class.for("https://dpp.go-data.at", "4") }
      .to raise_error(described_class::NoReader, /no reader DID is configured for the pod/)
  end
end
