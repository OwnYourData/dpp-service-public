# frozen_string_literal: true

require "digest"
require "json"
require "nokogiri"

# Reads the structure of a published AAS submodel template (AAS V3.0 XML) into
# the compact form AasView::Template works from: per submodel its idShort and
# semanticId, per element its idShort, model type, value type, semanticId, and
# from the concept description of that semanticId the unit and the value list.
# Nothing else is taken over -- no descriptions, no definitions, no example
# values.
#
#   bin/rails "dpp:aas:extract_battery_pass[/path/to/BatteryPassDataModel]"
#
# writes app/lib/aas_view/battery_pass_1_2_0.json from a checkout of the
# Battery Pass Data Model (CC BY 4.0). The checkout's commit and the SHA-256 of
# every file read are recorded in the result, so that it can be traced to its
# source.
class AasTemplateSource
  NS = { "aas" => "https://admin-shell.io/aas/3/0" }.freeze

  ELEMENT_TYPES = {
    "property" => "Property",
    "multiLanguageProperty" => "MultiLanguageProperty",
    "submodelElementCollection" => "SubmodelElementCollection",
    "submodelElementList" => "SubmodelElementList",
    "file" => "File"
  }.freeze

  def initialize(root, files)
    @root = root
    @files = files
  end

  def to_h(model:, version:, repository:, commit:, license:)
    submodels = []
    digests = {}
    @files.each do |relative|
      raw = File.binread(File.join(@root, relative))
      digests[relative] = Digest::SHA256.hexdigest(raw)
      document = parse(raw)
      concepts = concepts(document)
      document.xpath("//aas:submodels/aas:submodel", NS).each do |submodel|
        submodels << { "idShort" => text(submodel, "aas:idShort"),
                       "semanticId" => semantic_id(submodel),
                       "elements" => elements(submodel.xpath("aas:submodelElements/*", NS), concepts) }
      end
    end
    { "model" => model, "version" => version, "license" => license,
      "source" => { "repository" => repository, "commit" => commit, "files" => digests },
      "submodels" => submodels }
  end

  private

  # The files are UTF-16 with a byte order mark and claim UTF-8 in their XML
  # declaration; the declaration is dropped once the text is UTF-8.
  def parse(raw)
    text = if raw.start_with?("\xFF\xFE".b)
             raw.byteslice(2..).force_encoding(Encoding::UTF_16LE).encode(Encoding::UTF_8)
           elsif raw.start_with?("\xFE\xFF".b)
             raw.byteslice(2..).force_encoding(Encoding::UTF_16BE).encode(Encoding::UTF_8)
           else
             raw.dup.force_encoding(Encoding::UTF_8).delete_prefix("﻿")
           end
    Nokogiri::XML(text.sub(/\A\s*<\?xml[^>]*\?>/, ""), &:strict)
  end

  def concepts(document)
    document.xpath("//aas:conceptDescriptions/aas:conceptDescription", NS).to_h do |concept|
      spec = concept.at_xpath(".//aas:dataSpecificationIec61360", NS)
      unit = spec && text(spec, "aas:unit")
      values = spec ? spec.xpath(".//aas:valueReferencePair/aas:value", NS).map(&:text).uniq : []
      [text(concept, "aas:id"), { "unit" => unit, "values" => values.presence }.compact]
    end
  end

  def elements(nodes, concepts)
    nodes.filter_map { |node| element(node, concepts) }
  end

  def element(node, concepts)
    type = ELEMENT_TYPES[node.name]
    return nil if type.nil?

    semantic = semantic_id(node)
    out = { "idShort" => text(node, "aas:idShort"), "modelType" => type }
    out["semanticId"] = semantic if semantic
    case type
    when "Property"
      out["valueType"] = text(node, "aas:valueType")
      out.merge!(concepts.fetch(semantic, {}))
    when "MultiLanguageProperty", "File"
      out.merge!(concepts.fetch(semantic, {}).slice("values"))
    when "SubmodelElementCollection"
      out["elements"] = elements(node.xpath("aas:value/*", NS), concepts)
    when "SubmodelElementList"
      item = node.xpath("aas:value/*", NS).first
      out["item"] = element(item, concepts)&.except("idShort") if item
    end
    out
  end

  def semantic_id(node)
    node.at_xpath("aas:semanticId/aas:keys/aas:key/aas:value", NS)&.text.presence
  end

  def text(node, path)
    node.at_xpath(path, NS)&.text.presence
  end
end
