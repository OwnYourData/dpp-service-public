# frozen_string_literal: true

require "rails_helper"

# The Battery Pass Data Model 1.2.0 in the AAS view (AasView::Template,
# app/lib/aas_view/battery_pass_1_2_0.yml): the table checked against the
# model it names, and the rules of docs/AAS.md applied to the battery example
# of the DPP Manager.
RSpec.describe AasView::Template do
  let(:template) { described_class.all.find { |t| t.name == "Battery Pass Data Model 1.2.0" } }
  let(:passport) { JSON.parse(Rails.root.join("spec/fixtures/aas-vectors/source-battery.json").read) }
  let(:aas_id) { "https://dpp.example.org/dpp/v1/dpps/x/aas" }

  def bindings = template.bindings["submodels"].flat_map do |submodel, table|
    table.flat_map do |target, binding|
      next [[submodel, target, binding]] unless binding.key?("each")

      binding["fields"].map { |field, field_binding| [submodel, "#{target.delete_suffix('[]')}[]/#{field}", field_binding] }
    end
  end

  def submodels(document) = template.submodels(document, aas_id).to_h { |s| [s["idShort"], s["submodelElements"]] }

  def value_at(elements, *path)
    path.reduce(elements) do |current, step|
      return nil if current.nil?

      step.is_a?(Integer) ? current[step] : current.find { |e| e["idShort"] == step }&.then { |e| e["value"].is_a?(Array) && step != path.last ? e["value"] : e }
    end
  end

  def element(elements, id) = elements.find { |e| e["idShort"] == id }
  def item_values(list) = list["value"].map { |item| item["value"].to_h { |p| [p["idShort"], p["value"]] } }

  def change(path)
    copy = passport.deep_dup
    *parents, last = path.split("/")
    scope = parents.reduce(copy["elements"]) { |elements, id| elements.find { |e| e["elementId"] == id }["elements"] }
    yield scope.find { |e| e["elementId"] == last }, scope
    copy
  end

  describe "the structure" do
    it "comes from the published model, with the commit and a digest of every file it was read from" do
      source = template.structure["source"]

      expect(template.structure.values_at("model", "version", "license"))
        .to eq(["Battery Pass Data Model", "1.2.0", "CC-BY-4.0"])
      expect(source["repository"]).to eq("https://github.com/batterypass/BatteryPassDataModel")
      expect(source["commit"]).to match(/\A\h{40}\z/)
      expect(source["files"].size).to eq(7)
      expect(source["files"].values).to all(match(/\A\h{64}\z/))
      expect(template.structure["submodels"].map { |s| s["idShort"] }).to contain_exactly(
        "GeneralProductInformation", "CarbonFootprintForBatteries", "Circularity", "MaterialComposition",
        "PerformanceAndDurability", "SupplyChainDueDiligence", "Labeling"
      )
    end

    it "takes nothing over but identifiers, types, units and value lists" do
      keys = []
      walk = lambda do |node|
        keys.concat(node.keys)
        Array(node["elements"]).each(&walk)
        walk.call(node["item"]) if node["item"]
      end
      template.structure["submodels"].each(&walk)

      expect(keys.uniq - %w[idShort semanticId elements modelType valueType unit values item]).to be_empty
    end
  end

  describe "the table" do
    it "names only properties the model has" do
      bindings.each do |submodel, target, _|
        node = template.target(submodel, target)

        expect(node).not_to be_nil, "#{submodel}/#{target} is not in the model"
        expect(node["modelType"]).to eq("Property"), "#{submodel}/#{target} is a #{node['modelType']}"
      end
    end

    it "names a unit only where it stands for the unit of the model" do
      bindings.each do |submodel, target, binding|
        unit = template.target(submodel, target)["unit"] ||
               template.bindings["model_units"]["#{submodel}/#{target.gsub(/\[\d*\]/, '[]')}"]
        next if binding["unit"].nil? && (unit.nil? || template.bindings["counts"].include?(unit))

        expect(template.bindings["units"][binding["unit"]]).to eq(unit),
                                                               "#{submodel}/#{target}: #{binding['unit'].inspect} for #{unit.inspect}"
      end
    end

    it "supplies units only where the AAS files of the model leave them out" do
      template.bindings["model_units"].each_key do |path|
        submodel, target = path.split("/", 2)

        expect(template.target(submodel, target)).to include("modelType" => "Property")
        expect(template.target(submodel, target)["unit"]).to be_nil
      end
    end

    it "translates into the values of the model, and its constants are among them" do
      bindings.each do |submodel, target, binding|
        allowed = template.target(submodel, target)["values"]
        next if allowed.nil?

        given = binding.key?("values") ? binding["values"].values : [binding["value"]].compact
        expect(allowed).to include(*given), "#{submodel}/#{target}"
      end
    end

    it "fills every property it names from the battery example, 38 data elements in all" do
      sources = bindings.select { |_, _, binding| binding.key?("source") && !binding.key?("each") }
      filled = submodels(passport)

      expect(bindings.count { |_, target, binding| binding.key?("source") && !target.include?("[]") }).to eq(38)
      sources.each do |submodel, target, _|
        expect(filled[submodel]).not_to be_nil, submodel
      end
    end
  end

  describe "applied to the battery example" do
    it "fills six of the seven submodels and leaves Labeling out" do
      expect(submodels(passport).keys).to eq(%w[GeneralProductInformation CarbonFootprintForBatteries Circularity
                                                MaterialComposition PerformanceAndDurability SupplyChainDueDiligence])
    end

    it "translates the members of an enumeration, and lists the life cycle stages in the order of the table" do
      filled = submodels(passport)

      expect(element(filled["GeneralProductInformation"], "batteryCategory")["value"]).to eq("ev")
      stages = element(filled["CarbonFootprintForBatteries"], "carbonFootprintPerLifecycleStage")
      expect(item_values(stages)).to eq([
        { "lifecycleStage" => "RawMaterialExtraction", "carbonFootprint" => "38.9" },
        { "lifecycleStage" => "MainProduction", "carbonFootprint" => "17.2" },
        { "lifecycleStage" => "Distribution", "carbonFootprint" => "2.1" },
        { "lifecycleStage" => "Recycling", "carbonFootprint" => "3.2" }
      ])
      expect(stages["typeValueListElement"]).to eq("SubmodelElementCollection")
      expect(stages["value"].first).not_to have_key("idShort")
    end

    it "makes one item per child of a container" do
      materials = element(submodels(passport)["MaterialComposition"], "hazardousSubstances")

      expect(item_values(materials)).to eq([
        { "hazardousSubstanceName" => "Lithium hexafluorophosphate", "hazardousSubstanceConcentration" => "1.1",
          "hazardousSubstanceIdentifier" => "21324-40-3" },
        { "hazardousSubstanceName" => "Ethylene carbonate", "hazardousSubstanceConcentration" => "4.6",
          "hazardousSubstanceIdentifier" => "96-49-1" }
      ])
    end

    it "leaves out an element whose unit is another one" do
      document = change("BatteryIdentification/BatteryMass") { |e, _| e["unitOfMeasure"] = "t" }

      expect(element(submodels(document)["GeneralProductInformation"], "batteryMass")).to be_nil
    end

    it "leaves out a value the enumeration does not know" do
      document = change("BatteryIdentification/BatteryCategory") { |e, _| e["value"] = "SLIBattery" }

      expect(element(submodels(document)["GeneralProductInformation"], "batteryCategory")).to be_nil
    end

    it "leaves out a value that is not valid for the type of the model" do
      document = change("CarbonFootprint/BatteryCarbonFootprint") { |e, _| e["value"] = "about sixty" }

      expect(element(submodels(document)["CarbonFootprintForBatteries"], "batteryCarbonFootprint")).to be_nil
    end

    it "leaves out an item that would hold nothing but constants" do
      document = change("CarbonFootprint/RawMaterialAcquisitionContribution") { |e, scope| scope.delete(e) }
      stages = element(submodels(document)["CarbonFootprintForBatteries"], "carbonFootprintPerLifecycleStage")

      expect(item_values(stages).map { |item| item["lifecycleStage"] }).to eq(%w[MainProduction Distribution Recycling])
    end

    it "leaves out what a reader does not get, as PassportAccess leaves it out of the passport" do
      document = change("PerformanceAndDurability/StateOfCharge") { |e, scope| scope.delete(e) }
      condition = element(submodels(document)["PerformanceAndDurability"], "batteryCondition")

      expect(condition["value"].map { |e| e["idShort"] }).not_to include("stateOfCharge")
    end
  end

  it "applies only to a passport that has the element it recognises" do
    document = passport.merge("elements" => passport["elements"].reject { |e| e["elementId"] == "BatteryIdentification" })

    expect(template.submodels(document, aas_id)).to eq([])
    expect(template.submodels(DppRepresentation.passport(passport, "compressed"), aas_id)).to eq([])
  end
end
