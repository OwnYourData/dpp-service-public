# frozen_string_literal: true

require "rails_helper"

# The rqh claim (docs/Integrity.md section 11): base64url(SHA-256(METHOD LF
# TARGET LF base64url(SHA-256(BODY)))). The vectors are computed independently
# of this implementation, so a client in another language can check itself
# against them.
RSpec.describe RequestBinding do
  it "hashes method, request-target with its query and the body digest" do
    expect(described_class.body_digest('{"elements":[]}')).to eq("qR18we_3TLWpBNYHPddyTa7cacTUMt5ioWMKLlG_lKY")
    expect(described_class.digest("PATCH", "/dpp/v1/dpps/did%3Aoyd%3AzQmExample?representation=full",
                                  '{"elements":[]}')).to eq("WGgNu_mKYsHBy5viG29BhN08q9qznsS6mH22QZ2P7-8")
  end

  it "takes an empty body as the empty octet string, and the method in capitals" do
    expect(described_class.body_digest(nil)).to eq("47DEQpj8HBSa-_TImW-5JCeuQeRkm5NMpJWZG3hSuFU")
    expect(described_class.digest("delete", "/dpp/v1/dpps/x", "")).to eq("ULdlZ_iK5tIAER3kxGjUyaxwuG_1knNw0KlTUAMexaQ")
  end

  it "hashes bytes as they are: a different key order is a different body" do
    expect(described_class.body_digest('{"a":1,"b":2}')).not_to eq(described_class.body_digest('{"b":2,"a":1}'))
  end

  it "requires the binding from the configured day on" do
    allow(described_class).to receive(:required_from).and_call_original
    allow(ENV).to receive(:fetch).and_call_original
    allow(ENV).to receive(:fetch).with("DPP_REQUEST_BINDING_FROM", "2026-12-01").and_return("2026-12-01")

    expect(described_class.required?(today: Date.new(2026, 11, 30))).to be(false)
    expect(described_class.required?(today: Date.new(2026, 12, 1))).to be(true)
  end
end
