# frozen_string_literal: true

require "rails_helper"
require "ed25519"
require "jwt/eddsa"

# prEN 18239: the bearer token has to be verifiable. Here it is a self-issued
# JWT signed with the document key of the issuer's did:oyd.
#
# DID resolution is stubbed — these examples are about the verification rules,
# not about oydid, and they must run without network or libsodium.
RSpec.describe DidTokenVerifier do
  let(:did)         { "did:oyd:zQmWdUVpUGY8LdE1PVZUwz8gS7iwa1SfsWVoKx8CsDMFGeD" }
  let(:signing_key) { Ed25519::SigningKey.generate }
  let(:audience)    { "https://dpp-service.example" }

  def token(payload_overrides = {}, key: signing_key, algorithm: "EdDSA", header: {})
    now = Time.now.to_i
    payload = { "iss" => did, "sub" => did, "aud" => audience,
                "iat" => now, "exp" => now + 120, "jti" => SecureRandom.hex(8) }
        .merge(payload_overrides)
    JWT.encode(payload, key, algorithm, { "kid" => "#{did}#key-doc" }.merge(header))
  end

  before do
    allow(described_class).to receive(:audience).and_return(audience)
    allow(described_class).to receive(:resolve_public_key)
      .with(did).and_return(signing_key.verify_key.to_bytes)
    Rails.cache = ActiveSupport::Cache::MemoryStore.new
  end

  after { Rails.cache.clear }

  describe "a well-formed token" do
    it "returns the claims" do
      claims = described_class.call(token)
      expect(claims["iss"]).to eq(did)
      expect(claims["aud"]).to eq(audience)
    end
  end

  describe "rejections" do
    it "rejects a tampered signature without raising" do
      # Regression guard: the ed25519 library raises ArgumentError on a
      # malformed signature, not a JWT::DecodeError. Rescuing only the latter
      # would turn a forged token into a 500 instead of a 401.
      expect(described_class.call(token.sub(/\.[^.]+\z/, ".AAAA"))).to be_nil
    end

    it "rejects alg none" do
      unsigned = JWT.encode({ "iss" => did, "aud" => audience,
                              "exp" => Time.now.to_i + 60 }, nil, "none")
      expect(described_class.call(unsigned)).to be_nil
    end

    it "rejects a token signed by a different key" do
      expect(described_class.call(token(key: Ed25519::SigningKey.generate))).to be_nil
    end

    it "rejects a token addressed to another service" do
      expect(described_class.call(token({ "aud" => "https://somewhere.else" }))).to be_nil
    end

    it "rejects an expired token" do
      now = Time.now.to_i
      expect(described_class.call(token({ "iat" => now - 600, "exp" => now - 60 }))).to be_nil
    end

    it "rejects an issuer that is not a DID" do
      expect(described_class.call(token({ "iss" => "https://lumina.example" }))).to be_nil
    end

    it "rejects a sub that does not match iss" do
      expect(described_class.call(token({ "sub" => "did:oyd:zSomeoneElse" }))).to be_nil
    end

    it "rejects a token that lives longer than the allowed maximum" do
      now = Time.now.to_i
      expect(described_class.call(token({ "iat" => now, "exp" => now + described_class::MAX_LIFETIME + 60 })))
        .to be_nil
    end

    it "rejects garbage" do
      expect(described_class.call("not-a-token")).to be_nil
      expect(described_class.call(nil)).to be_nil
    end
  end

  describe "resolution cache" do
    it "resolves a DID once and serves further tokens from the cache" do
      3.times { described_class.call(token) }
      expect(described_class).to have_received(:resolve_public_key).once
    end

    it "caches a failed resolution too, so unknown DIDs cannot drive lookups" do
      unknown = "did:oyd:zUnknown"
      allow(described_class).to receive(:resolve_public_key).with(unknown).and_return(nil)

      3.times do
        described_class.call(JWT.encode({ "iss" => unknown, "aud" => audience,
                                          "iat" => Time.now.to_i,
                                          "exp" => Time.now.to_i + 60 },
                                        signing_key, "EdDSA"))
      end
      expect(described_class).to have_received(:resolve_public_key).with(unknown).once
    end
  end

  describe ".enabled?" do
    it "is off unless DPP_AUTH_MODE says otherwise" do
      allow(ENV).to receive(:fetch).and_call_original
      allow(ENV).to receive(:fetch).with("DPP_AUTH_MODE", "permissive").and_return("permissive")
      expect(described_class).not_to be_enabled
    end

    it "is on for did" do
      allow(ENV).to receive(:fetch).and_call_original
      allow(ENV).to receive(:fetch).with("DPP_AUTH_MODE", "permissive").and_return("did")
      expect(described_class).to be_enabled
    end
  end
end
