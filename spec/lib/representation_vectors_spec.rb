# frozen_string_literal: true

require "rails_helper"

# The vectors in spec/fixtures/representation-vectors are the specification of
# the full -> compressed conversion. pod-dpp carries a copy of DppRepresentation
# and ElementIdPath and runs the same vectors (test/representation_test.rb), so
# both answer a representation flag alike.
RSpec.describe "Representation vectors" do
  vectors = JSON.parse(Rails.root.join("spec/fixtures/representation-vectors/representation-vectors.json").read)

  it "names the two values of EN 18222:2026 8.1 and compressed as the default" do
    expect(DppRepresentation::VALUES).to match_array(vectors["valid"])
    expect(DppRepresentation.parse(nil)).to eq(vectors["default"])
  end

  vectors["invalid"].each do |value|
    it "refuses #{value.inspect}" do
      expect { DppRepresentation.parse(value) }.to raise_error(DppRepresentation::InvalidError)
    end
  end

  vectors["cases"].each do |vector|
    describe vector["name"] do
      it "converts the passport" do
        expect(DppRepresentation.passport(vector["full"], "compressed")).to eq(vector["compressed"])
        expect(DppRepresentation.passport(vector["full"], "full")).to eq(vector["full"])
      end

      vector["elements"].each do |element|
        it "selects #{element['path']} alike in both forms" do
          path = ElementIdPath.parse(element["path"])
          node = path.resolve(vector["full"])

          expect(node).to eq(element["full"])
          expect(path.resolve(vector["compressed"])).to eq(element["compressed"])
          next if node.nil?

          expect(DppRepresentation.element(node, "compressed", document: vector["full"])).to eq(element["compressed"])
        end
      end
    end
  end
end
