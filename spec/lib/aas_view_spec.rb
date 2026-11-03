# frozen_string_literal: true

require "rails_helper"

# AasView (docs/AAS.md): the passport as an AAS V3.0 environment. The vectors
# hold the whole result; this holds the rules one by one.
RSpec.describe AasView do
  let(:aas_id) { "https://dpp.example.org/dpp/v1/dpps/did%3Aoyd%3AzQmX/aas" }

  def view(document, source: {}) = described_class.environment(document, aas_id: aas_id, source: source)
  def shell(document) = view(document)["assetAdministrationShells"].first
  def submodel(document, id_short) = view(document)["submodels"].find { |s| s["idShort"] == id_short }
  def elements(elements) = submodel({ "elements" => elements }, "PassportElements")["submodelElements"]
  def single(id, value, **extra) = { "elementId" => id, "objectType" => "SingleValuedDataElement", "value" => value }.merge(extra.transform_keys(&:to_s))

  describe "the shell" do
    it "names the product as the asset, and takes the kind from the granularity" do
      { "item" => "Instance", "Item" => "Instance", "model" => "Type", "batch" => "NotApplicable",
        nil => "NotApplicable" }.each do |granularity, kind|
        info = shell("granularity" => granularity, "uniqueProductIdentifier" => "https://id.example.org/01/1")["assetInformation"]

        expect(info).to eq("assetKind" => kind, "globalAssetId" => "https://id.example.org/01/1")
      end
    end

    it "names the passport as the asset when the product identifier is missing" do
      expect(shell("digitalProductPassportId" => "did:oyd:zQmX")["assetInformation"]["globalAssetId"]).to eq("did:oyd:zQmX")
    end

    it "lists every submodel, named after the shell" do
      ids = shell({})["submodels"].map { |ref| ref["keys"].first["value"] }

      expect(ids).to eq(["#{aas_id}#DppMetadata", "#{aas_id}#PassportElements"])
    end

    it "says that it is not signed, and names the passport it comes from, leaving out what is unknown" do
      result = view({}, source: { "sourcePassport" => "https://dpp.example.org/dpp/v1/dpps/x?representation=full",
                                  "signatureState" => "signed", "payloadHash" => nil })
      shell = result["assetAdministrationShells"].first

      expect(shell["description"].first["text"]).to include("not signed by the economic operator")
      expect(shell["extensions"]).to eq([
                                          { "name" => "sourcePassport", "valueType" => "xs:anyURI",
                                            "value" => "https://dpp.example.org/dpp/v1/dpps/x?representation=full" },
                                          { "name" => "signatureState", "valueType" => "xs:string", "value" => "signed" }
                                        ])
      expect(view({})["assetAdministrationShells"].first).not_to have_key("extensions")
    end
  end

  describe "DppMetadata" do
    it "carries the header attributes under the identifiers of IDTA 02099-1" do
      document = { "digitalProductPassportId" => "did:oyd:zQmX", "granularity" => "item",
                   "lastUpdated" => "2026-11-03T10:00:00Z", "contentSpecificationIds" => ["EN 18223:2026"] }
      metadata = submodel(document, "DppMetadata")

      expect(metadata["semanticId"]["keys"].first["value"]).to eq("https://admin-shell.io/idta/cds/dppMetadata/1")
      expect(metadata["submodelElements"].map { |e| [e["idShort"], e["valueType"], e["valueType"] && e["value"]] }).to eq([
        ["digitalProductPassportId", "xs:string", "did:oyd:zQmX"],
        ["granularity", "xs:string", "item"],
        ["lastUpdate", "xs:dateTime", "2026-11-03T10:00:00Z"],
        ["contentSpecificationIds", nil, nil]
      ])
      list = metadata["submodelElements"].last
      expect(list["value"].map { |p| p["value"] }).to eq(["EN 18223:2026"])
      expect(list["value"].first).not_to have_key("idShort")
    end

    it "leaves out a timestamp that is none" do
      metadata = submodel({ "lastUpdated" => "yesterday" }, "DppMetadata")

      expect(metadata).not_to have_key("submodelElements")
    end
  end

  describe "PassportElements" do
    it "gives an elementId that is no idShort a valid one, keeps it as displayName, and keeps idShorts unique" do
      result = elements([single("Natural graphite", 1), single("Natural_graphite", 2), single("1st", 3),
                         single("Natural graphite", 4)])

      expect(result.map { |e| e["idShort"] }).to eq(%w[Natural_graphite Natural_graphite_2 E_1st Natural_graphite_3])
      expect(result.map { |e| e.dig("displayName", 0, "text") })
        .to eq(["Natural graphite", "Natural_graphite", "1st", "Natural graphite"])
    end

    it "types a value as declared when it is valid for the type, and by its JSON value otherwise" do
      result = elements([single("a", 412.5, valueDataType: "xsd:decimal"), single("b", 1.0e-05, valueDataType: "xsd:decimal"),
                         single("c", 3000, valueDataType: "xsd:integer"), single("d", "2026-06", valueDataType: "xsd:gYearMonth"),
                         single("e", "June", valueDataType: "xsd:gYearMonth"), single("f", 7.5), single("g", true),
                         single("h", "x", valueDataType: "xsd:unknown"), single("i", nil),
                         single("j", nil, valueDataType: "xsd:decimal")])

      expect(result.map { |e| [e["valueType"], e["value"]] }).to eq([
        ["xs:decimal", "412.5"], ["xs:decimal", "0.00001"], ["xs:integer", "3000"], ["xs:gYearMonth", "2026-06"],
        ["xs:string", "June"], ["xs:double", "7.5"], ["xs:boolean", "true"], ["xs:string", "x"], ["xs:string", nil],
        ["xs:decimal", nil]
      ])
    end

    it "carries the unit as a qualifier and the dictionary reference as semanticId" do
      property = elements([single("OnModePower", 8.5, unitOfMeasure: "W", dictionaryReference: "https://dict.example/p")]).first

      expect(property["qualifiers"]).to eq([{ "kind" => "ConceptQualifier", "type" => "unitOfMeasure",
                                              "valueType" => "xs:string", "value" => "W" }])
      expect(property["semanticId"]).to eq(described_class.reference("https://dict.example/p"))
    end

    it "lists the items of a multi-valued element without idShort, and their names as displayName" do
      list = elements([{ "elementId" => "Shares", "objectType" => "MultiValuedDataElement", "valueDataType" => "xsd:decimal",
                         "elements" => [single("Cobalt", 2.9), single("Lithium", 1.8)] }]).first

      expect(list).to include("modelType" => "SubmodelElementList", "typeValueListElement" => "Property",
                              "valueTypeListElement" => "xs:decimal")
      expect(list["value"].map { |i| [i["idShort"], i.dig("displayName", 0, "text"), i["value"]] })
        .to eq([[nil, "Cobalt", "2.9"], [nil, "Lithium", "1.8"]])
    end

    it "keeps the items of a multi-valued element as a collection where they differ in type or reference" do
      [[single("a", 1), single("b", "x")],
       [single("a", 1, dictionaryReference: "https://d.example/1"), single("b", 2, dictionaryReference: "https://d.example/2")]]
        .each do |items|
        element = elements([{ "elementId" => "Mixed", "objectType" => "MultiValuedDataElement", "elements" => items }]).first

        expect(element["modelType"]).to eq("SubmodelElementCollection")
        expect(element["value"].map { |e| e["idShort"] }).to eq(%w[a b])
      end
    end

    it "turns a multi-language element into a MultiLanguageProperty, and into a collection where a tag is invalid" do
      good = { "elementId" => "Name", "objectType" => "MultiLanguageDataElement",
               "value" => [{ "language" => "en-IE", "value" => "One" }, { "language" => "fr-CH", "value" => "Une" }] }
      bad = good.merge("value" => [{ "language" => "not a tag", "value" => "One" }])

      expect(elements([good]).first).to include("modelType" => "MultiLanguageProperty",
                                                "value" => [{ "language" => "en-IE", "text" => "One" },
                                                            { "language" => "fr-CH", "text" => "Une" }])
      expect(elements([bad]).first["modelType"]).to eq("SubmodelElementCollection")
    end

    it "turns a related resource into a File, with the title in the language of the resource" do
      resource = { "elementId" => "Manual", "objectType" => "RelatedResource", "url" => "https://d.example/m.pdf",
                   "contentType" => "application/pdf", "resourceTitle" => "Handbuch", "language" => "de" }

      expect(elements([resource]).first).to eq(
        "modelType" => "File", "idShort" => "Manual", "contentType" => "application/pdf",
        "value" => "https://d.example/m.pdf", "description" => [{ "language" => "de", "text" => "Handbuch" }]
      )
      file = elements([resource.except("contentType", "language")]).first
      expect(file["contentType"]).to eq("application/octet-stream")
      expect(file["description"]).to eq([{ "language" => "und", "text" => "Handbuch" }])
    end

    it "reads a compressed passport by the shape of its values, and leaves the header to DppMetadata" do
      result = submodel({ "digitalProductPassportId" => "did:oyd:zQmX", "Power" => 8.5, "Tags" => %w[a b],
                          "Box" => { "Depth" => 2 } }, "PassportElements")["submodelElements"]

      expect(result.map { |e| [e["idShort"], e["modelType"]] })
        .to eq([%w[Power Property], %w[Tags SubmodelElementList], %w[Box SubmodelElementCollection]])
    end
  end
end
