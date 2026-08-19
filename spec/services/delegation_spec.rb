# frozen_string_literal: true

require "rails_helper"
require "digest"

# Two halves, and the first is the important one.
#
# The conformance block signs the three statements of docs/Delegation.md §5–§6
# with the same inputs the fixture generator used and compares the result byte
# for byte with spec/fixtures/delegation-vectors/01-valid.json. That fixture is
# also what the pod is built against, so this is the seam where the two
# implementations either agree or fail loudly — a claim serialised in a
# different key order still looks identical in a diff of the claims and yet
# produces a signature the other side rejects.
#
# The second block covers what this service does when a customer hands it a
# delegation: everything in §8 that can be decided without the pod's state.
RSpec.describe Delegation do
  def vector_dir
    Rails.root.join("spec/fixtures/delegation-vectors")
  end

  # The generator derives every seed from a label instead of storing keys.
  def key_for(label)
    Ed25519::SigningKey.new(Digest::SHA256.digest("dpp-delegation-vector/#{label}"))
  end

  def jti_for(label)
    Digest::SHA256.hexdigest("dpp-delegation-vector/jti/#{label}")[0, 16]
  end

  describe "conformance with the delegation vectors" do
    let(:vector)  { JSON.parse(vector_dir.join("01-valid.json").read) }
    let(:now)     { vector["now"] }
    let(:pod)     { "https://dpp.go-data.at" }
    let(:token_endpoint) { "#{pod}/oauth/token" }
    let(:holder)  { key_for("holder") }
    let(:service) { key_for("service") }
    let(:holder_did)  { vector["collection"]["controller_did"] }
    let(:service_did) do
      described_class.peek(vector["request"]["form"]["client_assertion"])["iss"]
    end

    it "reproduces the delegation assertion byte for byte" do
      mine = described_class.sign(
        holder,
        typ: described_class::TYP_DELEGATION,
        kid: "#{holder_did}#key-doc",
        payload: { "iss" => holder_did, "sub" => service_did, "aud" => pod,
                   "collection" => "4",
                   "product_id" => "https://id.lumina.example/01/09520123456791",
                   "act" => %w[create update delete],
                   "purpose" => "dpp-hosting",
                   "iat" => now, "nbf" => now, "exp" => now + (90 * 86_400),
                   "jti" => jti_for("delegation/01") }
      )

      expect(mine).to eq(vector["request"]["form"]["assertion"])
    end

    it "reproduces the client assertion byte for byte" do
      mine = described_class.client_assertion(token_endpoint, now: now,
                                              jti: jti_for("client-assertion/01"),
                                              did: service_did, key: service)

      expect(mine).to eq(vector["request"]["form"]["client_assertion"])
    end

    it "reproduces the DPoP proof byte for byte" do
      mine = described_class.dpop_proof(htm: "POST", htu: token_endpoint, now: now,
                                        jti: jti_for("dpop/01"), key: service)

      expect(mine).to eq(vector["request"]["headers"]["DPoP"])
    end

    it "computes the thumbprint the pod binds the token to" do
      jkt = described_class.jkt(described_class.jwk_for(service.verify_key))

      expect(jkt).to eq(vector["expect"]["cnf_jkt"])
    end

    it "keeps the short-lived statements short (§10)" do
      ca = described_class.peek(
        described_class.client_assertion(token_endpoint, now: now, did: service_did, key: service)
      )
      expect(ca["exp"] - ca["iat"]).to eq(described_class::CLIENT_ASSERTION_LIFETIME)
      expect(described_class::DPOP_LIFETIME).to eq(30)
    end
  end

  describe ".verify!" do
    let(:now)         { 1_786_960_000 }
    let(:pod)         { "https://dpp.go-data.at" }
    let(:holder)      { key_for("holder") }
    let(:holder_did)  { "did:oyd:zHolderTestIdentity" }
    let(:service_did) { "did:oyd:zServiceTestIdentity" }

    # Both parameters are positional on purpose. With a keyword parameter here,
    # Ruby 3 reads delegation("sub" => "x") as keyword arguments and raises
    # "unknown keyword: sub" instead of building the token — a failure that
    # looks like a bug in the code under test.
    def delegation(overrides = {}, signing_key = nil)
      payload = { "iss" => holder_did, "sub" => service_did, "aud" => pod,
                  "collection" => "4",
                  "product_id" => "https://id.lumina.example/01/09520123456791",
                  "act" => %w[create update], "purpose" => "dpp-hosting",
                  "iat" => now, "nbf" => now, "exp" => now + (90 * 86_400),
                  "jti" => "b2f1c9e4a7d05386" }.merge(overrides)
      described_class.sign(signing_key || holder, typ: described_class::TYP_DELEGATION,
                                                  kid: "#{holder_did}#key-doc", payload: payload)
    end

    def verify(token, **opts)
      described_class.verify!(token, audience: pod, collection_id: "4",
                                     service_did: service_did, now: now, **opts)
    end

    before do
      allow(DidTokenVerifier).to receive(:public_key_for)
        .with(holder_did).and_return(holder.verify_key)
    end

    it "accepts a well-formed delegation and returns its claims" do
      claims = verify(delegation)

      expect(claims["iss"]).to eq(holder_did)
      expect(claims["act"]).to eq(%w[create update])
    end

    it "refuses a delegation signed by someone else" do
      expect { verify(delegation({}, key_for("other-holder"))) }
        .to raise_error(described_class::Invalid, /signature/)
    end

    it "refuses an issuer whose DID does not resolve" do
      allow(DidTokenVerifier).to receive(:public_key_for).with(holder_did).and_return(nil)

      expect { verify(delegation) }.to raise_error(described_class::Invalid, /cannot resolve/)
    end

    it "refuses a delegation addressed to another service (§8 rule 8)" do
      expect { verify(delegation("sub" => "did:oyd:zSomeoneElse")) }
        .to raise_error(described_class::Invalid, /not this service/)
    end

    it "refuses a delegation for another pod (§8 rule 3)" do
      expect { verify(delegation("aud" => "https://other.pod.example")) }
        .to raise_error(described_class::Invalid, /is not #{Regexp.escape(pod)}/)
    end

    it "refuses a delegation for another collection" do
      expect { verify(delegation("collection" => "9")) }
        .to raise_error(described_class::Invalid, /collection/)
    end

    it "refuses an expired delegation (§8 rule 4)" do
      expect { verify(delegation("iat" => now - 200, "nbf" => now - 200, "exp" => now - 100)) }
        .to raise_error(described_class::Invalid, /expired/)
    end

    it "refuses one that is not valid yet" do
      expect { verify(delegation("nbf" => now + 600, "iat" => now + 600, "exp" => now + 900)) }
        .to raise_error(described_class::Invalid, /not valid yet/)
    end

    it "refuses a lifetime beyond the maximum" do
      expect { verify(delegation("exp" => now + (400 * 86_400))) }
        .to raise_error(described_class::Invalid, /exceeds/)
    end

    it "refuses a wildcard product_id (D2)" do
      error = nil
      begin
        verify(delegation("product_id" => "*"))
      rescue described_class::Invalid => e
        error = e
      end

      expect(error.message).to match(/product_id/)
      expect(error.code).to eq("invalid_grant")
    end

    it "refuses an unknown act value with insufficient_scope (D3)" do
      error = nil
      begin
        verify(delegation("act" => %w[create publish]))
      rescue described_class::Invalid => e
        error = e
      end

      expect(error.message).to match(/publish/)
      expect(error.code).to eq("insufficient_scope")
    end

    it "refuses an empty act" do
      expect { verify(delegation("act" => [])) }
        .to raise_error(described_class::Invalid, /non-empty/)
    end

    it "refuses a foreign typ (RFC 8725 §3.11)" do
      token = described_class.sign(holder, typ: described_class::TYP_CLIENT,
                                           kid: "#{holder_did}#key-doc",
                                           payload: { "iss" => holder_did })

      expect { verify(token) }.to raise_error(described_class::Invalid, /typ/)
    end

    it "refuses a missing claim rather than defaulting it" do
      token = described_class.sign(holder, typ: described_class::TYP_DELEGATION,
                                           kid: "#{holder_did}#key-doc",
                                           payload: { "iss" => holder_did, "sub" => service_did })

      expect { verify(token) }.to raise_error(described_class::Invalid, /is missing/)
    end

    it "refuses something that is not a JWS at all" do
      expect { verify("not-a-token") }.to raise_error(described_class::Invalid)
    end
  end

  describe ".covers?" do
    let(:claims) { { "act" => %w[create update], "exp" => 1_786_960_000 + 100 } }

    it "is true for a permitted operation inside the validity window" do
      expect(described_class.covers?(claims, "update", now: 1_786_960_000)).to be(true)
    end

    it "is false for an operation the delegation does not name" do
      expect(described_class.covers?(claims, "delete", now: 1_786_960_000)).to be(false)
    end

    it "is false once the delegation has expired" do
      expect(described_class.covers?(claims, "create", now: 1_786_970_000)).to be(false)
    end
  end

  describe "canonical serialisation" do
    it "sorts keys at every level" do
      json = described_class.canonical("b" => 1, "a" => { "d" => 2, "c" => 3 })

      expect(json).to eq('{"a":{"c":3,"d":2},"b":1}')
    end

    it "refuses non-ASCII instead of guessing an escaping" do
      expect { described_class.canonical("purpose" => "dpp-hösting") }
        .to raise_error(described_class::Error, /non-ASCII/)
    end
  end
end
