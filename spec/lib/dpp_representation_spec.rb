# frozen_string_literal: true

require "rails_helper"

# EN 18222:2026 8.1 lets a client choose between the compressed representation
# (EN 18223:2026 5.2, the default) and the full one (EN 18223:2026 Annex A).
# The service stores the full form and converts in exactly one place.
RSpec.describe DppRepresentation do
  let(:header) do
    {
      "digitalProductPassportId" => "did:oyd:zQmExample",
      "uniqueProductIdentifier" => "https://dpp.example.org/01/09520123456788/21/000001",
      "granularity" => "item",
      "dppSchemaVersion" => "EN 18223:2026",
      "dppStatus" => "Active",
      "lastUpdated" => "2026-10-09T08:00:00Z",
      "economicOperatorId" => "did:oyd:zQmOperator",
      "contentSpecificationIds" => ["EN 18223:2026"]
    }
  end

  def single(id, value, type = nil)
    { "elementId" => id, "objectType" => "SingleValuedDataElement",
      "dictionaryReference" => "https://dictionary.example/#{id}",
      "valueDataType" => type, "value" => value }.compact
  end

  # The structure of EN 18223:2026 5.2.5 in the expanded form of Annex A,
  # Example 1, with the other classes of 4.1.2 added.
  let(:full) do
    header.merge(
      "elements" => [
        { "elementId" => "performanceMetrics", "objectType" => "DataElementCollection",
          "dictionaryReference" => "https://dictionary.example/performanceMetrics",
          "elements" => [
            single("maxPressure", 750.0, "xsd:float"),
            single("isFireResistant", true, "xsd:boolean"),
            { "elementId" => "efficiencyRatings", "objectType" => "MultiValuedDataElement",
              "valueDataType" => "xsd:float",
              "elements" => [single("r1", 0.95), single("r2", 0.92), single("r3", 0.88)] },
            { "elementId" => "complexTraits", "objectType" => "MultiValuedDataElement",
              "elements" => [
                { "elementId" => "t1", "objectType" => "DataElementCollection",
                  "elements" => [single("fieldOne", 1.0), single("fieldTwo", "stringValueOne")] },
                { "elementId" => "t2", "objectType" => "DataElementCollection",
                  "elements" => [single("fieldOne", 2.0), single("fieldTwo", "stringValueTwo")] }
              ] }
          ] },
        # Annex A, Example 4: the items of a multi-valued element in "value".
        { "elementId" => "supportedVoltages", "objectType" => "MultiValuedDataElement",
          "value" => [single("v1", 110), single("v2", 220), single("v3", 240)] },
        { "elementId" => "userManual", "objectType" => "RelatedResource",
          "dictionaryReference" => "https://dictionary.example/document/userManual",
          "resourceTitle" => "User Manual", "contentType" => "application/pdf",
          "url" => "https://data.example.com/manual.pdf", "language" => "en-GB" },
        { "elementId" => "productDescription", "objectType" => "MultiLanguageDataElement",
          "value" => [{ "language" => "en-IE", "value" => "One Thing" },
                      { "language" => "fr-CH", "value" => "Une Chose" }] }
      ]
    )
  end

  let(:compressed) do
    header.merge(
      "performanceMetrics" => {
        "maxPressure" => 750.0,
        "isFireResistant" => true,
        "efficiencyRatings" => [0.95, 0.92, 0.88],
        "complexTraits" => [
          { "fieldOne" => 1.0, "fieldTwo" => "stringValueOne" },
          { "fieldOne" => 2.0, "fieldTwo" => "stringValueTwo" }
        ]
      },
      "supportedVoltages" => [110, 220, 240],
      "userManual" => { "resourceTitle" => "User Manual", "contentType" => "application/pdf",
                        "url" => "https://data.example.com/manual.pdf", "language" => "en-GB" },
      "productDescription" => [{ "language" => "en-IE", "value" => "One Thing" },
                               { "language" => "fr-CH", "value" => "Une Chose" }]
    )
  end

  describe ".parse" do
    it "defaults to compressed when the flag is absent (8.1)" do
      expect(described_class.parse(nil)).to eq("compressed")
    end

    it "takes the two values of 8.1" do
      expect(described_class.parse("compressed")).to eq("compressed")
      expect(described_class.parse("full")).to eq("full")
    end

    ["", "bogus", "Full", "FULL", "Compressed", " full", "full ", "expanded"].each do |raw|
      it "refuses #{raw.inspect}" do
        expect { described_class.parse(raw) }.to raise_error(DppRepresentation::InvalidError, /EN 18222:2026 8.1/)
      end
    end

    it "refuses a structured value (representation[]=full)" do
      expect { described_class.parse(["full"]) }.to raise_error(DppRepresentation::InvalidError)
    end
  end

  describe ".full_url" do
    it "adds representation=full to an address without a query" do
      expect(described_class.full_url("https://dpp.go-data.at/dpp/v1/dppsByProductId/https%3A%2F%2Fa.example%2F01"))
        .to eq("https://dpp.go-data.at/dpp/v1/dppsByProductId/https%3A%2F%2Fa.example%2F01?representation=full")
    end

    it "keeps other parameters and replaces a representation already there" do
      expect(described_class.full_url("https://s.example/dpp/v1/dpps/x?a=1&representation=compressed"))
        .to eq("https://s.example/dpp/v1/dpps/x?a=1&representation=full")
    end
  end

  describe ".passport" do
    it "converts the full form into the compressed form of EN 18223:2026 5.2" do
      expect(described_class.passport(full, "compressed")).to eq(compressed)
    end

    it "puts the header first (5.2.4)" do
      expect(described_class.passport(full, "compressed").keys.first(header.size)).to eq(header.keys)
    end

    it "returns the full form as stored" do
      expect(described_class.passport(full, "full")).to equal(full)
    end

    it "leaves a document without elements alone in both representations" do
      expect(described_class.passport(compressed, "compressed")).to eq(compressed)
      expect(described_class.passport(compressed, "full")).to eq(compressed)
    end

    it "drops attributes 5.2.2 leaves to the data dictionary, including extra ones on a value" do
      doc = header.merge("elements" => [
                           { "elementId" => "LuminousFlux", "objectType" => "SingleValuedDataElement",
                             "valueDataType" => "xsd:integer", "unitOfMeasure" => "lm", "value" => 806 }
                         ])
      expect(described_class.passport(doc, "compressed")).to eq(header.merge("LuminousFlux" => 806))
    end

    it "keeps a header attribute when an element carries the same name" do
      doc = header.merge("elements" => [single("granularity", "x")])
      expect(described_class.passport(doc, "compressed")["granularity"]).to eq("item")
    end

    it "does not change the stored document" do
      before = full.deep_dup
      described_class.passport(full, "compressed")
      expect(full).to eq(before)
    end
  end

  describe ".element" do
    it "is the value the element has in the compressed passport" do
      expect(described_class.element(single("maxPressure", 750.0), "compressed", document: full)).to eq(750.0)
      expect(described_class.element(full["elements"][0], "compressed", document: full))
        .to eq(compressed["performanceMetrics"])
    end

    it "is the element object of Annex A in the full form" do
      element = single("maxPressure", 750.0)
      expect(described_class.element(element, "full", document: full)).to equal(element)
    end

    it "is not converted again when it comes out of a compressed document" do
      node = { "elementId" => "x", "value" => 1 } # a collection with children named so
      expect(described_class.element(node, "compressed", document: compressed)).to equal(node)
    end
  end

  # The elementIdPath is evaluated on the compressed form (EN 18222:2026 8.1,
  # RFC 9535). Whatever the path selects in the stored full document, converted,
  # has to be what the same path selects in the compressed passport.
  describe "agreement with ElementIdPath" do
    ["$.performanceMetrics", "$.performanceMetrics.maxPressure", "$.performanceMetrics.efficiencyRatings",
     "$.performanceMetrics.efficiencyRatings[1]", "$.performanceMetrics.efficiencyRatings[-1]",
     "$.performanceMetrics.complexTraits[0]", "$.performanceMetrics.complexTraits[1].fieldTwo",
     "$.supportedVoltages[2]", "$.userManual", "$.productDescription", "$.productDescription[1]",
     "$['performanceMetrics']['isFireResistant']"].each do |path|
      it "selects the same element for #{path}" do
        query = ElementIdPath.parse(path)
        expected = query.resolve(compressed)

        expect(expected).not_to be_nil
        expect(described_class.element(query.resolve(full), "compressed", document: full)).to eq(expected)
      end
    end
  end
end
