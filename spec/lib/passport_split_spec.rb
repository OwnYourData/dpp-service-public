# frozen_string_literal: true

require "rails_helper"

RSpec.describe PassportSplit do
  def single(id, value) = { "elementId" => id, "objectType" => "SingleValuedDataElement", "value" => value }
  def coll(id, *children) = { "elementId" => id, "objectType" => "DataElementCollection", "elements" => children }

  let(:document) do
    { "digitalProductPassportId" => "did:oyd:zQmX", "dppStatus" => "Active",
      "elements" => [
        coll("Identification", single("Model", "A60"), single("Batch", "LOT-42")),
        coll("Composition", single("Material", "PC")),
        { "elementId" => "Voltages", "objectType" => "MultiValuedDataElement", "value" => [220, 230] },
        single("Recycled", 12)
      ] }
  end
  let(:controlled) { %w[Identification/Batch Composition/Material Recycled] }

  def parts = described_class.split(document) { |path| controlled.include?(path) }

  it "puts each attribute on exactly one side" do
    pub, ctl = parts
    expect(described_class.attribute_paths(pub)).to eq(%w[Identification/Model Voltages])
    expect(described_class.attribute_paths(ctl)).to eq(controlled)
  end

  it "keeps a collection with children on both sides on both sides, with its metadata" do
    pub, ctl = parts
    expect(pub["elements"].first.except("elements")).to eq(coll("Identification").except("elements"))
    expect(ctl["elements"].first.except("elements")).to eq(coll("Identification").except("elements"))
  end

  it "keeps a list whole, as AccessPolicy classifies it" do
    pub, = parts
    expect(pub["elements"].find { |e| e["elementId"] == "Voltages" }["value"]).to eq([220, 230])
  end

  it "gives both sides the same header" do
    pub, ctl = parts
    expect(ctl.except("elements")).to eq(pub.except("elements"))
  end

  it "puts the two sides back together into the same attributes" do
    pub, ctl = parts
    whole = described_class.merge(described_class.public_payload(pub, described_class.controlled_payload(ctl)),
                                  described_class.controlled_payload(ctl))
    expect(described_class.attribute_paths(whole)).to match_array(described_class.attribute_paths(document))
    expect(whole.to_json).not_to include("ControlledData")
  end

  it "takes an attribute that is on both sides from the controlled side" do
    pub = { "elements" => [single("Recycled", 10)] }
    ctl = { "elements" => [single("Recycled", 12)] }
    expect(described_class.merge(pub, ctl)["elements"]).to eq([single("Recycled", 12)])
  end

  it "drops elements a passport sends under the service's names" do
    sneaky = document.merge("elements" => document["elements"] + [single("ControlledData", "zQmFake")])
    pub, ctl = described_class.split(sneaky) { false }
    expect(pub.to_json + ctl.to_json).not_to include("zQmFake")
  end

  it "names the controlled payload by a digest that changes with the salt" do
    _, ctl = parts
    first = described_class.controlled_payload(ctl)
    second = described_class.controlled_payload(ctl)
    expect(described_class.digest(first)).not_to eq(described_class.digest(second))
    expect(described_class.digest(first)).to eq(described_class.digest(JSON.parse(JSON.generate(first.to_a.reverse.to_h))))
  end
end
