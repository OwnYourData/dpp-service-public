# frozen_string_literal: true

require "rails_helper"

# Each attribute of a passport gets exactly one access class. Two examples are
# checked attribute by attribute: the LED lamp used throughout the service and a
# small battery passport whose classes follow the access groups of the Battery
# Regulation (Article 77(2), Annex XIII); its attributes are named freely,
# after the kinds of information DIN DKE SPEC 99100 describes.
RSpec.describe AccessPolicy do
  let(:fixtures) { Rails.root.join("spec/fixtures") }
  let(:scheme)   { AccessClass::SCHEME }

  def passport(name) = JSON.parse(File.read(fixtures.join(name)))

  def policy(rules, extra = {})
    described_class.new({ "id" => "https://example.org/policy/1", "scheme" => scheme,
                          "rules" => rules }.merge(extra))
  end

  def notations(classification) = classification.classes.transform_values(&:notation)

  let(:header) do
    %w[digitalProductPassportId uniqueProductIdentifier granularity dppSchemaVersion
       dppStatus economicOperatorId facilityId]
  end

  describe "the LED lamp" do
    subject(:result) do
      described_class.load(fixtures.join("access-policies/lightbulb-policy.json"))
                     .classify(passport("representation-vectors/source-lightbulb.json"))
    end

    it "gives every attribute exactly one class" do
      expected = header.to_h { |name| [name, "public"] }.merge(
        "ProductIdentification/ModelIdentifier" => "public",
        "ProductIdentification/BrandName" => "public",
        "ProductIdentification/LightSourceType" => "public",
        "ProductIdentification/CapType" => "public",
        "EnergyPerformance/OnModePower" => "public",
        "EnergyPerformance/LuminousFlux" => "public",
        "EnergyPerformance/LuminousEfficacy" => "public",
        "EnergyPerformance/EnergyEfficiencyClass" => "public",
        "EnergyPerformance/EprelRegistrationNumber" => "public",
        "LightQuality/CorrelatedColourTemperature" => "public",
        "LightQuality/ColourRenderingIndex" => "public",
        "LightQuality/Dimmable" => "public",
        "Durability/RatedLifetime" => "public",
        "Durability/SwitchingCycles" => "public",
        "SubstancesOfConcern/MercuryContent" => "public",
        "SubstancesOfConcern/MaterialComposition" => "legitimateInterest",
        "DeclarationOfConformity" => "public"
      )

      expect(notations(result)).to eq(expected)
    end

    it "leaves nothing to the default and uses every rule" do
      expect(result.unclassified).to be_empty
      expect(result.unused_rules).to be_empty
    end

    it "classifies the items of the material list with the list, not one by one" do
      expect(result.classes.keys.grep(%r{MaterialComposition/})).to be_empty
    end
  end

  describe "the battery" do
    subject(:result) do
      described_class.load(fixtures.join("access-policies/battery-policy.json"))
                     .classify(passport("access-policies/battery-passport.json"))
    end

    it "gives every attribute exactly one class" do
      expected = (header + ["lastUpdated"]).to_h { |name| [name, "public"] }.merge(
        "Identification/BatteryIdentifier" => "public",
        "Identification/ManufacturerIdentifier" => "public",
        "Identification/ManufacturingPlace" => "public",
        "Identification/ManufacturingDate" => "public",
        "General/BatteryCategory" => "public",
        "General/BatteryMass" => "public",
        "General/WarrantyPeriod" => "public",
        "General/ServiceStartDate" => "legitimateInterest",
        "General/BatteryStatus" => "legitimateInterest",
        "CarbonFootprint/TotalCarbonFootprint" => "public",
        "CarbonFootprint/CarbonFootprintClass" => "public",
        "Composition/CathodeChemistry" => "legitimateInterest",
        "Composition/CriticalRawMaterials" => "legitimateInterest",
        "Composition/HazardousSubstances" => "public",
        "Dismantling/DismantlingManual" => "legitimateInterest",
        "Dismantling/SparePartsContact" => "legitimateInterest",
        "Performance/StateOfHealth" => "legitimateInterest",
        "Performance/RemainingCapacity" => "legitimateInterest",
        "Compliance/DeclarationOfConformity" => "public",
        "Compliance/TestReportResults" => "authority"
      )

      expect(notations(result)).to eq(expected)
    end

    it "uses all three classes, as the three access groups of the regulation do" do
      expect(result.by_class.transform_values(&:size)).to eq(
        "public" => 19, "legitimateInterest" => 8, "authority" => 1
      )
    end

    it "leaves nothing to the default and uses every rule" do
      expect(result.unclassified).to be_empty
      expect(result.unused_rules).to be_empty
    end
  end

  describe "how a class is found" do
    let(:document) { passport("access-policies/battery-passport.json") }

    it "lets a deeper rule override the rule on its collection" do
      result = policy([{ "path" => "Composition", "accessClass" => "authority" },
                       { "path" => "Composition/HazardousSubstances", "accessClass" => "public" }])
               .classify(document)

      expect(result.class_of("Composition/CathodeChemistry").notation).to eq("authority")
      expect(result.class_of("Composition/HazardousSubstances").notation).to eq("public")
    end

    it "gives an attribute no rule reaches the most restrictive class, and says so" do
      result = policy([{ "path" => "Identification", "accessClass" => "public" }]).classify(document)

      expect(result.class_of("General/BatteryMass").notation).to eq("authority")
      expect(result.unclassified).to include("General/BatteryMass", "Compliance/TestReportResults")
      expect(result.unclassified).not_to include("Identification/BatteryIdentifier")
    end

    it "takes the policy's own default instead, where it names one" do
      result = policy([], "default" => "legitimateInterest").classify(document)

      expect(result.class_of("General/BatteryMass").notation).to eq("legitimateInterest")
    end

    it "keeps the header public whatever the default" do
      result = policy([]).classify(document)

      header.each { |name| expect(result.class_of(name).notation).to eq("public") }
    end

    it "reports a rule that reaches no attribute, such as one on an item of a list" do
      result = policy([{ "path" => "Composition/CriticalRawMaterials/Material1", "accessClass" => "public" },
                       { "path" => "Nowhere", "accessClass" => "public" }]).classify(document)

      expect(result.unused_rules).to contain_exactly("Composition/CriticalRawMaterials/Material1", "Nowhere")
      expect(result.class_of("Composition/CriticalRawMaterials").notation).to eq("authority")
    end

    it "classifies a passport without data elements by its header alone" do
      result = policy([]).classify(document.except("elements"))

      expect(result.classes.values.map(&:notation).uniq).to eq(["public"])
    end

    it "refuses a data element without an elementId rather than leaving it out" do
      broken = document.merge("elements" => [{ "objectType" => "SingleValuedDataElement", "value" => 1 }])

      expect { policy([]).classify(broken) }.to raise_error(described_class::InvalidError, /elementId/)
    end
  end

  describe "reading a policy" do
    it "accepts a class by its IRI as well as by its notation" do
      read = policy([{ "path" => "A", "accessClass" => "#{scheme}#authority" }])

      expect(read.rules["A"].notation).to eq("authority")
    end

    {
      "a rule on a header attribute" => [{ "path" => "facilityId", "accessClass" => "authority" }],
      "a class outside the vocabulary" => [{ "path" => "A", "accessClass" => "confidential" }],
      "two rules for one path" => [{ "path" => "A", "accessClass" => "public" },
                                   { "path" => "A", "accessClass" => "authority" }],
      "an empty segment in a path" => [{ "path" => "A//B", "accessClass" => "public" }],
      "a rule with another member" => [{ "path" => "A", "accessClass" => "public", "roles" => ["x"] }]
    }.each do |what, rules|
      it "refuses #{what}" do
        expect { policy(rules) }.to raise_error(described_class::InvalidError)
      end
    end

    it "refuses another scheme" do
      expect { policy([], "scheme" => "https://example.org/other") }
        .to raise_error(described_class::InvalidError, /scheme/)
    end

    it "refuses a policy without an id or without rules" do
      expect { described_class.new("scheme" => scheme, "rules" => []) }.to raise_error(described_class::InvalidError, /id/)
      expect { described_class.new("id" => "https://example.org/policy/1", "scheme" => scheme) }
        .to raise_error(described_class::InvalidError, /rules/)
    end

    ["x", "policy/1", "https://example.org/a b", "https://example.org/stra\u00dfe", ""].each do |id|
      it "refuses #{id.inspect} as id, which is no absolute URI in printable ASCII" do
        expect { described_class.new("id" => id, "scheme" => scheme, "rules" => []) }
          .to raise_error(described_class::InvalidError, /id/)
      end
    end

    it "refuses unknown members, so that a misspelt default is not ignored" do
      expect { policy([], "defualt" => "public") }.to raise_error(described_class::InvalidError, /defualt/)
    end

    it "refuses text that is not JSON" do
      expect { described_class.parse("{not json") }.to raise_error(described_class::InvalidError)
    end
  end
  describe "#visible_for" do
    let(:policy)   { described_class.load(fixtures.join("access-policies/battery-policy.json")) }
    let(:document) { passport("access-policies/battery-passport.json") }

    def attributes(roles) = PassportSplit.attribute_paths(policy.visible_for(roles, document))

    it "keeps the public attributes only for a reader without roles" do
      expect(attributes([]).size).to eq(19 - header.size - 1)
      expect(attributes([])).not_to include("General/ServiceStartDate", "Compliance/TestReportResults")
    end

    it "adds legitimateInterest for that role, and authority only for authority" do
      expect(attributes(["legitimateInterest"])).to include("General/ServiceStartDate")
      expect(attributes(["legitimateInterest"])).not_to include("Compliance/TestReportResults")
      expect(attributes(["authority"])).to include("General/ServiceStartDate", "Compliance/TestReportResults")
    end

    it "keeps the header for every reader and takes roles by IRI as well" do
      expect(policy.visible_for([], document).keys).to include(*header)
      expect(attributes(["#{AccessClass::SCHEME}#authority"])).to eq(attributes(["authority"]))
    end

    it "opens nothing for a role that is no class" do
      expect(attributes(["recycler"])).to eq(attributes([]))
    end

    it "leaves the elements of this service out" do
      with_digest = document.merge("elements" => document["elements"] + [
                                     { "elementId" => "ControlledData", "objectType" => "SingleValuedDataElement",
                                       "value" => "z123" }
                                   ])
      expect(PassportSplit.attribute_paths(policy.visible_for(["authority"], with_digest)))
        .not_to include("ControlledData")
    end
  end

  describe "#public_at?" do
    let(:rules) do
      [{ "path" => "General", "accessClass" => "public" },
       { "path" => "General/SerialNumber", "accessClass" => "legitimateInterest" },
       { "path" => "Compliance", "accessClass" => "authority" }]
    end

    it "judges a path by the policy alone, whether a passport has the element or not" do
      with_default = policy(rules, "default" => "public")

      expect(with_default.public_at?(%w[General BrandName])).to be(true)
      expect(with_default.public_at?(%w[General SerialNumber])).to be(false)
      expect(with_default.public_at?(%w[Compliance AnyReport])).to be(false)
      expect(with_default.public_at?(%w[NoSuchElement])).to be(true)
    end

    it "is not public for a collection a controlled rule lies below" do
      expect(policy(rules, "default" => "public").public_at?(%w[General])).to be(false)
    end

    it "gives a path no rule reaches the default, or the most restrictive class without one" do
      expect(policy(rules).public_at?(%w[NoSuchElement])).to be(false)
      expect(policy([], "default" => "public").public_at?(%w[NoSuchElement])).to be(true)
    end

    it "asks the whole passport when there are no segments" do
      expect(policy([], "default" => "public").public_at?([])).to be(true)
      expect(policy(rules, "default" => "public").public_at?([])).to be(false)
    end

    it "keeps the header attributes public" do
      expect(policy(rules).public_at?(%w[economicOperatorId])).to be(true)
    end
  end
end
