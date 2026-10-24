# frozen_string_literal: true

require "rails_helper"

# bin/verify_writes: what the owner checks in an export of the write log, with
# nothing but the entries and the keys of the DIDs that signed the tokens.
RSpec.describe WriteEvidence do
  let(:owner) { "did:oyd:zQmEvidenceOwner" }
  let(:key)   { Ed25519::SigningKey.new(Digest::SHA256.digest("evidence/owner")) }
  let(:other) { Ed25519::SigningKey.new(Digest::SHA256.digest("evidence/other")) }
  let(:resolve) { ->(kid) { kid == "#{owner}#key-doc" ? key.verify_key : nil } }
  let(:now) { Time.utc(2026, 10, 25, 12) }

  def b64(bytes) = Base64.urlsafe_encode64(bytes, padding: false)

  def token(claims, signing_key: key)
    head = b64(JSON.generate({ "alg" => "EdDSA", "typ" => "JWT", "kid" => "#{owner}#key-doc" }))
    body = b64(JSON.generate(claims))
    "#{head}.#{body}.#{b64(signing_key.sign("#{head}.#{body}"))}"
  end

  # One write as the export has it: request and outcome.
  def write(n, version:, body: "{\"n\":#{n}}", target: "/dpp/v1/dpps/x", bind: true, signing_key: key, jti: "j#{n}",
            status: 200, at: now + n)
    rqh = RequestBinding.digest("PATCH", target, body)
    claims = { "iss" => owner, "sub" => owner, "iat" => at.to_i - 5, "exp" => at.to_i + 300, "jti" => jti }
    claims["rqh"] = rqh if bind
    [{ "phase" => "request", "requestId" => "r#{n}", "at" => at.iso8601(6), "operation" => "UpdateDPPById",
       "issuer" => owner, "jti" => jti, "token" => token(claims, signing_key: signing_key),
       "rqh" => (rqh if bind), "method" => "PATCH", "target" => target,
       "bodyDigest" => RequestBinding.body_digest(body) }.compact,
     { "phase" => "outcome", "requestId" => "r#{n}", "at" => (at + 1).iso8601(6), "status" => status,
       "version" => version }]
  end

  def check(entries) = described_class.new(entries.flatten, resolve: resolve).check

  it "verifies bound writes whose versions follow one another" do
    evidence = check([write(1, version: 2), write(2, version: 3)])

    expect(evidence).not_to be_failed
    expect(evidence.count(:bound)).to eq(2)
  end

  it "lists a write taken without a request hash as open, not as failed" do
    evidence = check([write(1, version: 2, bind: false)])

    expect(evidence).not_to be_failed
    expect(evidence.count(:unbound)).to eq(1)
  end

  it "fails a token that does not verify with the key of its issuer" do
    expect(check([write(1, version: 2, signing_key: other)])).to be_failed
  end

  it "fails a recorded body digest the token does not bind" do
    request, outcome = write(1, version: 2)
    request["bodyDigest"] = RequestBinding.body_digest("{\"n\":99}")

    evidence = check([request, outcome])

    expect(evidence).to be_failed
    expect(evidence.findings.map(&:text)).to include("the rqh does not match the method, target and body recorded")
  end

  it "fails a jti that comes twice, a write without outcome, and a version without a write" do
    expect(check([write(1, version: 2), write(2, version: 3, jti: "j1")])).to be_failed
    expect(check([write(1, version: 2).first])).to be_failed
    expect(check([write(1, version: 2), write(2, version: 4)]).findings.map(&:text))
      .to include("version 3 has no recorded write")
  end

  it "fails a write outside the lifetime of its token" do
    request, outcome = write(1, version: 2)
    request["at"] = (now + 3600).iso8601(6)

    expect(check([request, outcome])).to be_failed
  end
end
