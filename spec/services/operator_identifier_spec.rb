# frozen_string_literal: true

require "rails_helper"

# EN 18223:2026 Table 1 has economicOperatorId "formatted according to
# EN 18219:2026"; Clause 6 of EN 18219 gives the four schemes checked here.
RSpec.describe OperatorIdentifier do
  {
    "did:oyd:zQmX493GLVxE8Wasc8ANTdZmq4YUsvdk5j6Daf7iQaPECt6" => 8,
    "did:oyd:zQmX493GLVxE8Wasc8ANTdZmq4YUsvdk5j6Daf7iQaPECt6@oydid.ownyourdata.eu" => 8,
    "did:web:lumina.example" => 8,
    "0199:5299000J2N45DDNE4Y28" => 6,
    "0223:ATU12345678" => 6,
    "https://id.gs1.org/417/9520123456788" => 7,
    "https://doi.org/10.5281/zenodo.1234567" => 7,
    "10.5281/zenodo.1234567" => 9,
    "doi:10.5281/zenodo.1234567" => 9
  }.each do |value, scheme|
    it "reads #{value} as ID scheme #{scheme}" do
      expect(described_class.scheme(value)).to eq(scheme)
    end
  end

  [
    nil, "", "Lumina GmbH", "ATU12345678", "http://id.lumina.example/op",
    "did:", "DID:oyd:abc", "199:5299000J2N45DDNE4Y28", "0199: 5299000J2N45DDNE4Y28",
    "urn:lei:5299000J2N45DDNE4Y28"
  ].each do |value|
    it "refuses #{value.inspect}" do
      expect(described_class.valid?(value)).to be(false)
    end
  end
end
