# frozen_string_literal: true

require "rails_helper"

# The compact JWS the economic operator signs a passport with
# (docs/Integrity.md section 10), shared by the service and bin/sign_dpp and
# bin/verify_dpp.
RSpec.describe CompactJws do
  let(:key)     { Ed25519::SigningKey.new(Digest::SHA256.digest("compact-jws/key")) }
  let(:other)   { Ed25519::SigningKey.new(Digest::SHA256.digest("compact-jws/other")) }
  let(:kid)     { "did:oyd:zQmOperator#key-doc" }
  let(:payload) { %({"digitalProductPassportId":"did:oyd:zQmPassport","elements":[{"elementId":"BrandName","value":"Lümina"}]}) }

  it "signs the payload bytes as they are, with alg and kid in the protected header" do
    jws = described_class.parse(described_class.sign(payload, key, kid: kid))

    expect(jws.header).to eq("alg" => "EdDSA", "kid" => kid)
    expect(jws.payload_bytes.force_encoding(Encoding::UTF_8)).to eq(payload)
    expect(jws.payload["elements"].first["value"]).to eq("Lümina")
    expect(jws.signer).to eq("did:oyd:zQmOperator")
  end

  it "verifies with the signer's key and with no other" do
    jws = described_class.parse(described_class.sign(payload, key, kid: kid))

    expect(described_class.valid?(jws, key.verify_key)).to be(true)
    expect(described_class.valid?(jws, other.verify_key)).to be(false)
    expect(described_class.valid?(jws, nil)).to be(false)
  end

  it "does not verify a payload that was changed after signing" do
    head, _, signature = described_class.sign(payload, key, kid: kid).split(".")
    changed = described_class.encode(payload.sub("Lümina", "Lumina"))

    expect(described_class.valid?(described_class.parse("#{head}.#{changed}.#{signature}"), key.verify_key)).to be(false)
  end

  it "refuses what is not a compact JWS" do
    ["", "a.b", "a.b.c.d", "!!.b.c", ".e30.c", "#{described_class.encode('[]')}.e30.c"].each do |text|
      expect { described_class.parse(text) }.to raise_error(described_class::Malformed), text
    end
  end
end
