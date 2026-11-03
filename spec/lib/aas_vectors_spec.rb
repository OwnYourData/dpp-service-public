# frozen_string_literal: true

require "rails_helper"

# The vectors in spec/fixtures/aas-vectors are the specification of the AAS
# view (docs/AAS.md). A custodian that carries a copy of AasView runs the same
# vectors.
RSpec.describe "AAS vectors" do
  vectors = JSON.parse(Rails.root.join("spec/fixtures/aas-vectors/aas-vectors.json").read)

  it "are written for AAS V#{AasView::VERSION}" do
    expect(vectors["aasVersion"]).to eq(AasView::VERSION)
  end

  vectors["cases"].each do |vector|
    it "derive the environment of #{vector['name']}" do
      environment = AasView.environment(vector["passport"], aas_id: vector["aasId"], source: vector["source"])

      expect(environment).to eq(vector["environment"])
    end
  end

  it "start from the compressed form of the passport the representation vectors start from" do
    full = JSON.parse(Rails.root.join("spec/fixtures/representation-vectors/source-en18223.json").read)
    compressed = vectors["cases"].find { |v| v["name"] == "compressed" }["passport"]

    expect(compressed).to eq(DppRepresentation.passport(full, "compressed"))
  end
end
