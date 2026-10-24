# frozen_string_literal: true

require "rails_helper"

# EN 18222:2026 8.1: elementIdPath follows RFC 9535. ReadDataElement and
# UpdateDataElement address one element, so the accepted form is the singular
# query; everything else is refused before the document is touched.
RSpec.describe ElementIdPath do
  let(:expanded) do
    {
      "digitalProductPassportId" => "did:oyd:zQmExample",
      "granularity" => "item",
      "elements" => [
        { "elementId" => "ProductIdentification", "objectType" => "DataElementCollection",
          "elements" => [
            { "elementId" => "ModelIdentifier", "objectType" => "SingleValuedDataElement",
              "value" => "LUM-A60-827-806" },
            { "elementId" => "odd name/with 'quotes'", "objectType" => "SingleValuedDataElement",
              "value" => "x" }
          ] },
        { "elementId" => "efficiencyRatings", "objectType" => "MultiValuedDataElement",
          "elements" => [
            { "elementId" => "r1", "objectType" => "SingleValuedDataElement", "value" => 0.95 },
            { "elementId" => "r2", "objectType" => "SingleValuedDataElement", "value" => 0.92 }
          ] }
      ]
    }
  end

  let(:compressed) do
    {
      "digitalProductPassportId" => "did:oyd:zQmExample",
      "granularity" => "item",
      "ProductIdentification" => { "ModelIdentifier" => "LUM-A60-827-806" },
      "efficiencyRatings" => [0.95, 0.92]
    }
  end

  def resolve(path, document = expanded)
    described_class.parse(path).resolve(document)
  end

  describe "singular queries on the expanded form (EN 18223:2026 Annex A)" do
    it "follows dot-notation names" do
      expect(resolve("$.ProductIdentification.ModelIdentifier")["value"]).to eq("LUM-A60-827-806")
    end

    it "follows bracketed names in either quote style, with escapes" do
      expect(resolve("$['ProductIdentification'][\"ModelIdentifier\"]")["value"]).to eq("LUM-A60-827-806")
      expect(resolve("$.ProductIdentification['odd name/with \\'quotes\\'']")["value"]).to eq("x")
      expect(resolve("$['Product\\u0049dentification'].ModelIdentifier")["value"]).to eq("LUM-A60-827-806")
    end

    it "allows blank space between segments and inside brackets" do
      expect(resolve("$ .ProductIdentification[ 'ModelIdentifier' ]")["value"]).to eq("LUM-A60-827-806")
    end

    it "selects the n-th item of a multi-valued element, counting from the end when negative" do
      expect(resolve("$.efficiencyRatings[0]")["value"]).to eq(0.95)
      expect(resolve("$.efficiencyRatings[-1]")["value"]).to eq(0.92)
      expect(resolve("$.efficiencyRatings[2]")).to be_nil
    end

    it "does not treat header attributes or element fields as data elements" do
      expect(resolve("$.granularity")).to be_nil
      expect(resolve("$.ProductIdentification.ModelIdentifier.value")).to be_nil
    end

    it "designates nothing with the root alone" do
      expect(resolve("$")).to be_nil
    end
  end

  describe "singular queries on the compressed form (EN 18223:2026 5.2)" do
    it "walks the document as plain JSON" do
      expect(resolve("$.ProductIdentification.ModelIdentifier", compressed)).to eq("LUM-A60-827-806")
      expect(resolve("$.efficiencyRatings[1]", compressed)).to eq(0.92)
    end

    it "does not select header attributes" do
      expect(resolve("$.granularity", compressed)).to be_nil
    end
  end

  it "reads a path of element identifiers separated by '/'" do
    expect(resolve("ProductIdentification/ModelIdentifier")["value"]).to eq("LUM-A60-827-806")
  end

  it "names the element identifiers up to the first index, which an access policy can classify" do
    expect(described_class.parse("$.ProductIdentification.ModelIdentifier").leading_names)
      .to eq(%w[ProductIdentification ModelIdentifier])
    expect(described_class.parse("$['EnergyPerformance'].efficiencyRatings[1].x").leading_names)
      .to eq(%w[EnergyPerformance efficiencyRatings])
    expect(described_class.parse("$[0].ModelIdentifier").leading_names).to eq([])
    expect(described_class.parse("A/B").leading_names).to eq(%w[A B])
  end

  it "locates the container, so that an update can replace the element in place" do
    document = expanded.deep_dup
    container, key = described_class.parse("$.ProductIdentification.ModelIdentifier").locate(document)
    container[key] = { "elementId" => "ModelIdentifier", "value" => "NEW" }

    expect(document.dig("elements", 0, "elements", 0, "value")).to eq("NEW")
  end

  describe "refusals" do
    ["$[", "$.", "$..", "$ ", "$.1abc", "$['unterminated", "$[01]", "$[-0]", "$['\\x']",
     "$[9007199254740992]", "$['\\uD800']", "$.a b"].each do |query|
      it "refuses #{query.inspect} as not RFC 9535" do
        expect { described_class.parse(query) }.to raise_error(ElementIdPath::InvalidError)
      end
    end

    ["$.*", "$[*]", "$..ModelIdentifier", "$[0:2]", "$[?@.value]", "$['a','b']", "$[0,1]"].each do |query|
      it "refuses #{query.inspect} as valid JSONPath that is not singular" do
        expect { described_class.parse(query) }.to raise_error(ElementIdPath::NotSingularError)
      end
    end

    it "refuses an empty path" do
      expect { described_class.parse("") }.to raise_error(ElementIdPath::InvalidError)
    end
  end
end
