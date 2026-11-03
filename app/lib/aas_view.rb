# frozen_string_literal: true

require "bigdecimal"
require "date"
require "json"
require "uri"
require "yaml"

# A passport as an Asset Administration Shell (AAS V3.0, JSON): a view derived
# from the passport as it was read, for clients that work with AAS
# (docs/AAS.md).
#
#   shell             one per passport; globalAssetId is the
#                     uniqueProductIdentifier, assetKind follows granularity
#   DppMetadata       the header attributes of EN 18223:2026 Table 1, with the
#                     identifiers of the submodel template IDTA 02099-1
#   PassportElements  every data element of the passport, one to one
#   template models   for a passport a template recognises, its submodels as
#                     far as the passport's elements fit them
#                     (AasView::Template, so far the Battery Pass Data Model
#                     1.2.0)
#
# The view is not covered by the signature of the economic operator, and the
# service does not sign it either. The shell says so in its description and
# names the signed passport in its extensions.
#
# Plain Ruby, no Rails: a custodian that serves the EN 18222 read paths itself
# can carry a copy of this file and of the data files in aas_view/, as it does
# with DppRepresentation. Both are held to the vectors in
# spec/fixtures/aas-vectors.
module AasView
  VERSION = "3.0"

  HEADER = %w[digitalProductPassportId uniqueProductIdentifier granularity dppSchemaVersion dppStatus
              lastUpdated economicOperatorId facilityId contentSpecificationIds].freeze

  DESCRIPTION = "Derived from the digital product passport (EN 18223) at the time it was read. It is not " \
                "signed by the economic operator: the signed passport is the one named in the extension " \
                "sourcePassport."

  # EN 18223 granularity -> AssetKind of AAS V3.0, which knows no batch.
  ASSET_KINDS = { "item" => "Instance", "model" => "Type" }.freeze

  module_function

  # +document+: the passport as read, full or compressed. +aas_id+: the
  # identifier of the shell, the submodels are named after it. +source+:
  # what the shell says about the passport it comes from -- "sourcePassport",
  # "signatureState" and "payloadHash", each left out when nil.
  def environment(document, aas_id:, source: {})
    document = {} unless document.is_a?(Hash)
    submodels = [Metadata.submodel(document, "#{aas_id}#DppMetadata"),
                 Elements.submodel(document, "#{aas_id}#PassportElements")]
    submodels += Template.all.flat_map { |template| template.submodels(document, aas_id) }
    { "assetAdministrationShells" => [shell(document, aas_id, submodels, source)], "submodels" => submodels }
  end

  def shell(document, aas_id, submodels, source)
    kind = ASSET_KINDS.fetch(document["granularity"].to_s.downcase, "NotApplicable")
    asset = document["uniqueProductIdentifier"]
    asset = document["digitalProductPassportId"] unless asset.is_a?(String) && !asset.empty?
    shell = { "modelType" => "AssetAdministrationShell", "id" => aas_id, "idShort" => "DigitalProductPassport",
              "description" => [{ "language" => "en", "text" => DESCRIPTION }] }
    extensions = extensions(source)
    shell["extensions"] = extensions unless extensions.empty?
    shell["assetInformation"] = { "assetKind" => kind }
    shell["assetInformation"]["globalAssetId"] = asset.to_s if asset.is_a?(String) && !asset.empty?
    shell["submodels"] = submodels.map do |submodel|
      { "type" => "ModelReference", "keys" => [{ "type" => "Submodel", "value" => submodel["id"] }] }
    end
    shell
  end

  def extensions(source)
    { "sourcePassport" => "xs:anyURI", "signatureState" => "xs:string", "payloadHash" => "xs:string" }
      .filter_map do |name, type|
        value = source[name] || source[name.to_sym]
        next if value.nil? || value.to_s.empty?

        { "name" => name, "valueType" => type, "value" => value.to_s }
      end
  end

  def reference(id)
    { "type" => "ExternalReference", "keys" => [{ "type" => "GlobalReference", "value" => id }] }
  end

  # Without the members AAS V3.0 does not allow to be empty.
  def compact(element)
    element.reject { |key, value| value.is_a?(Array) && value.empty? && OPTIONAL_LISTS.include?(key) }
  end

  OPTIONAL_LISTS = %w[value submodelElements qualifiers description displayName extensions].freeze

  # Data types and lexical forms of XML Schema, as AAS V3.0 takes them
  # (DataTypeDefXsd). A value is only ever given the type it is valid for.
  module Value
    INTEGER_RANGES = {
      "integer" => [nil, nil], "long" => [-2**63, 2**63 - 1], "int" => [-2**31, 2**31 - 1],
      "short" => [-2**15, 2**15 - 1], "byte" => [-128, 127], "unsignedLong" => [0, 2**64 - 1],
      "unsignedInt" => [0, 2**32 - 1], "unsignedShort" => [0, 65_535], "unsignedByte" => [0, 255],
      "positiveInteger" => [1, nil], "nonNegativeInteger" => [0, nil], "negativeInteger" => [nil, -1],
      "nonPositiveInteger" => [nil, 0]
    }.freeze

    TZ = '(Z|[+-]((0\d|1[0-3]):[0-5]\d|14:00))?'
    YEAR = '-?([1-9]\d{3,}|0\d{3})'
    PATTERNS = {
      "boolean" => /\A(true|false|1|0)\z/,
      "decimal" => /\A[+-]?(\d+(\.\d*)?|\.\d+)\z/,
      "double" => /\A([+-]?(\d+(\.\d*)?|\.\d+)([Ee][+-]?\d+)?|[+-]?INF|NaN)\z/,
      "float" => /\A([+-]?(\d+(\.\d*)?|\.\d+)([Ee][+-]?\d+)?|[+-]?INF|NaN)\z/,
      "gYearMonth" => /\A#{YEAR}-(0[1-9]|1[0-2])#{TZ}\z/,
      "gYear" => /\A#{YEAR}#{TZ}\z/,
      "gMonth" => /\A--(0[1-9]|1[0-2])#{TZ}\z/,
      "gDay" => /\A---(0[1-9]|[12]\d|3[01])#{TZ}\z/,
      "gMonthDay" => /\A--(0[1-9]|1[0-2])-(0[1-9]|[12]\d|3[01])#{TZ}\z/,
      "time" => /\A(([01]\d|2[0-3]):[0-5]\d:[0-5]\d(\.\d+)?|24:00:00(\.0+)?)#{TZ}\z/,
      "duration" => /\A-?P(?=\d|T\d)(\d+Y)?(\d+M)?(\d+D)?(T(?=\d)(\d+H)?(\d+M)?(\d+(\.\d+)?S)?)?\z/,
      "hexBinary" => /\A([0-9a-fA-F]{2})*\z/,
      "base64Binary" => %r{\A[A-Za-z0-9+/\s]*={0,2}\z},
      # No blanks, controls or characters RFC 3987 leaves out, and a valid
      # scheme where there is one.
      "anyURI" => %r{\A(?![^:/?#]*:)[^\s<>"{}|\\^`]*\z|\A[A-Za-z][A-Za-z0-9+.-]*:[^\s<>"{}|\\^`]*\z}
    }.freeze

    TYPES = (%w[string date dateTime] + PATTERNS.keys + INTEGER_RANGES.keys).freeze

    module_function

    # "xs:<type>" for a declared valueDataType (xsd:decimal, xs:decimal or
    # decimal) the value is valid for, or that has no value; otherwise the
    # type the JSON value has.
    def type_for(declared, value)
      local = declared.to_s.sub(/\A(xsd|xs):/, "")
      return "xs:#{local}" if TYPES.include?(local) && (value.nil? || valid?(value, "xs:#{local}"))

      inferred(value)
    end

    def inferred(value)
      case value
      when true, false then "xs:boolean"
      when Integer then "xs:integer"
      when Float then value.finite? ? "xs:double" : "xs:string"
      else "xs:string"
      end
    end

    # The lexical form of +value+ for +type+ ("xs:..."), or nil if it has none.
    def lexical(value, type)
      local = type.to_s.delete_prefix("xs:")
      text = format(value, local)
      return nil if text.nil?

      valid_text?(text, local) ? text : nil
    end

    def valid?(value, type) = !lexical(value, type).nil?

    def format(value, local)
      case value
      when nil, Hash, Array then nil
      when true, false then value.to_s
      when Integer then value.to_s
      when Float
        return nil unless value.finite?

        local == "decimal" || INTEGER_RANGES.key?(local) ? decimal_text(value, local) : value.to_s
      else value.to_s
      end
    end

    def decimal_text(value, local)
      text = BigDecimal(value.to_s).to_s("F")
      return text if local == "decimal"

      text.end_with?(".0") ? text.delete_suffix(".0") : text
    end

    def valid_text?(text, local)
      return true if local == "string"
      return integer?(text, local) if INTEGER_RANGES.key?(local)
      return date?(text) if local == "date"
      return date_time?(text) if local == "dateTime"

      PATTERNS.fetch(local).match?(text)
    end

    def integer?(text, local)
      return false unless /\A[+-]?\d+\z/.match?(text)

      low, high = INTEGER_RANGES.fetch(local)
      number = text.to_i
      (low.nil? || number >= low) && (high.nil? || number <= high)
    end

    def date?(text)
      match = /\A(#{YEAR})-(\d{2})-(\d{2})#{TZ}\z/.match(text)
      match && Date.valid_date?(match[1].to_i, match[3].to_i, match[4].to_i)
    end

    def date_time?(text)
      match = /\A(#{YEAR})-(\d{2})-(\d{2})T(([01]\d|2[0-3]):[0-5]\d:[0-5]\d(\.\d+)?|24:00:00(\.0+)?)#{TZ}\z/
              .match(text)
      match && Date.valid_date?(match[1].to_i, match[3].to_i, match[4].to_i)
    end

    # An idShort of AAS V3.0 (AASd-002): a letter, then letters, digits and
    # "_", at most 128 characters.
    def id_short(name)
      text = name.to_s.gsub(/[^A-Za-z0-9_]/, "_")
      text = "E_#{text}" unless /\A[A-Za-z]/.match?(text)
      text[0, 128]
    end

    LANGUAGE = /\A([a-zA-Z]{2,3}(-[a-zA-Z]{3}){0,3}|[a-zA-Z]{4,8})(-[a-zA-Z]{4})?(-([a-zA-Z]{2}|\d{3}))?
                (-([a-zA-Z0-9]{5,8}|\d[a-zA-Z0-9]{3}))*(-[0-9A-WY-Za-wy-z](-[a-zA-Z0-9]{2,8})+)*
                (-[xX](-[a-zA-Z0-9]{1,8})+)?\z/x

    def language?(tag) = tag.is_a?(String) && LANGUAGE.match?(tag)
  end

  # The submodel of IDTA 02099-1 (Digital Product Passport, part 1, DPP
  # metadata): the header attributes of the passport under the template's
  # identifiers. The template calls lastUpdated lastUpdate.
  module Metadata
    CDS = "https://admin-shell.io/idta/cds/"

    ATTRIBUTES = [
      %w[digitalProductPassportId digitalProductPassportId xs:string],
      %w[uniqueProductIdentifier uniqueProductIdentifier xs:string],
      %w[granularity granularity xs:string],
      %w[dppSchemaVersion dppSchemaVersion xs:string],
      %w[dppStatus dppStatus xs:string],
      %w[lastUpdated lastUpdate xs:dateTime],
      %w[economicOperatorId economicOperatorId xs:string],
      %w[facilityId facilityId xs:string]
    ].freeze

    module_function

    def submodel(document, id)
      elements = ATTRIBUTES.filter_map do |attribute, id_short, type|
        value = Value.lexical(document[attribute], type)
        next if value.nil?

        { "modelType" => "Property", "idShort" => id_short, "semanticId" => AasView.reference("#{CDS}#{id_short}/1"),
          "valueType" => type, "value" => value }
      end
      ids = Array(document["contentSpecificationIds"]).select { |entry| entry.is_a?(String) && !entry.empty? }
      elements << content_specification_ids(ids) if ids.any?
      AasView.compact({ "modelType" => "Submodel", "id" => id, "idShort" => "DppMetadata", "kind" => "Instance",
                        "semanticId" => AasView.reference("#{CDS}dppMetadata/1"), "submodelElements" => elements })
    end

    def content_specification_ids(ids)
      item = AasView.reference("#{CDS}contentSpecificationId/1")
      { "modelType" => "SubmodelElementList", "idShort" => "contentSpecificationIds",
        "semanticId" => AasView.reference("#{CDS}contentSpecificationIds/1"),
        "semanticIdListElement" => item, "typeValueListElement" => "Property", "valueTypeListElement" => "xs:string",
        "value" => ids.map do |id|
          { "modelType" => "Property", "semanticId" => item, "valueType" => "xs:string", "value" => id }
        end }
    end
  end

  # PassportElements: the element tree of the passport, one to one.
  #
  #   DataElementCollection     SubmodelElementCollection
  #   SingleValuedDataElement   Property; unitOfMeasure as qualifier
  #   MultiValuedDataElement    SubmodelElementList, items without idShort
  #                             (AASd-120) and their elementId as displayName;
  #                             a SubmodelElementCollection where the items
  #                             differ in kind, type or reference
  #   MultiLanguageDataElement  MultiLanguageProperty
  #   RelatedResource           File: url, contentType, resourceTitle as
  #                             description in the language of the resource
  #
  # dictionaryReference becomes the semanticId. An elementId that is no valid
  # idShort is rewritten and kept as displayName. A compressed passport is read
  # by the shape of its JSON values.
  module Elements
    METADATA = %w[elementId objectType dictionaryReference valueDataType unitOfMeasure].freeze
    UNKNOWN_TYPE = "application/octet-stream"
    CONTENT_TYPE = %r{\A[!#$%&'*+.^_`|~0-9A-Za-z-]+/[!#$%&'*+.^_`|~0-9A-Za-z-]+(\s*;.*)?\z}
    TEXT_LIMIT = 1023
    NAME_LIMIT = 128

    module_function

    def submodel(document, id)
      AasView.compact({ "modelType" => "Submodel", "id" => id, "idShort" => "PassportElements", "kind" => "Instance",
                        "description" => [{ "language" => "en", "text" => "Every data element of the passport, one to one." }],
                        "submodelElements" => named(members(document)) })
    end

    # [name, node] of the data elements: "elements" of the full form, the
    # members other than the header in the compressed one.
    def members(document)
      if document["elements"].is_a?(Array)
        document["elements"].select { |e| e.is_a?(Hash) }.map { |e| [e["elementId"], e] }
      else
        document.reject { |key, _| HEADER.include?(key) }.to_a
      end
    end

    # Elements of a collection, each with a unique idShort (AASd-022).
    def named(pairs)
      taken = []
      pairs.map do |name, node|
        element = convert(node, name)
        display = name.to_s
        base = Value.id_short(display.empty? ? element["modelType"] : display)
        short = base
        short = "#{base[0, 120]}_#{taken.count { |t| t.start_with?(base) } + 1}" while taken.include?(short)
        taken << short
        entry = { "modelType" => element.delete("modelType"), "idShort" => short }
        entry["displayName"] = [{ "language" => "en", "text" => display[0, NAME_LIMIT] }] if !display.empty? && display != short
        AasView.compact(entry.merge(element))
      end
    end

    def convert(node, name)
      return value_node(node) unless node.is_a?(Hash)

      case node["objectType"]
      when "DataElementCollection" then collection(node)
      when "SingleValuedDataElement" then property(node)
      when "MultiValuedDataElement" then list(node)
      when "MultiLanguageDataElement" then multi_language(node)
      when "RelatedResource" then file(node)
      else inferred(node, name)
      end
    end

    def collection(node)
      element = { "modelType" => "SubmodelElementCollection" }
      reference(element, node)
      children = Array(node["elements"]).select { |child| child.is_a?(Hash) }
      element["value"] = named(children.map { |child| [child["elementId"], child] })
      element
    end

    def property(node, declared = nil)
      value = node["value"]
      type = Value.type_for(node["valueDataType"] || declared, value)
      element = { "modelType" => "Property" }
      reference(element, node)
      unit = node["unitOfMeasure"]
      if unit.is_a?(String) && !unit.empty?
        element["qualifiers"] = [{ "kind" => "ConceptQualifier", "type" => "unitOfMeasure",
                                   "valueType" => "xs:string", "value" => unit }]
      end
      element["valueType"] = type
      text = Value.lexical(value, type)
      text = JSON.generate(value) if text.nil? && (value.is_a?(Hash) || value.is_a?(Array))
      element["value"] = text unless text.nil?
      element
    end

    # Items of a multi-valued element: listed in "elements" or in "value".
    def list(node)
      items = node["elements"].is_a?(Array) ? node["elements"] : Array(node["value"])
      items = items.select { |item| item.is_a?(Hash) }
      converted = items.map do |item|
        if item["objectType"] == "SingleValuedDataElement"
          property(item, node["valueDataType"])
        else
          convert(item, item["elementId"])
        end
      end
      unless listable?(converted)
        element = { "modelType" => "SubmodelElementCollection" }
        reference(element, node)
        element["value"] = named(items.map { |item| [item["elementId"], item] })
        return element
      end

      element = { "modelType" => "SubmodelElementList" }
      reference(element, node)
      first = converted.first
      element["semanticIdListElement"] = first["semanticId"] if first && first["semanticId"]
      element["typeValueListElement"] = first ? first["modelType"] : "SubmodelElement"
      element["valueTypeListElement"] = first["valueType"] if first && first["modelType"] == "Property"
      element["value"] = converted.each_with_index.map do |item, index|
        name = items[index]["elementId"].to_s
        listed = { "modelType" => item.delete("modelType") }
        listed["displayName"] = [{ "language" => "en", "text" => name[0, NAME_LIMIT] }] unless name.empty?
        AasView.compact(listed.merge(item))
      end
      element
    end

    # AASd-107, AASd-108, AASd-109, AASd-114: the items of a list share their
    # kind, their value type and their reference.
    def listable?(items)
      items.map { |item| [item["modelType"], item["valueType"], item["semanticId"]] }.uniq.size <= 1 &&
        items.none? { |item| item["modelType"] == "Property" && !item.key?("value") }
    end

    def multi_language(node)
      entries = node["elements"].is_a?(Array) ? node["elements"] : Array(node["value"])
      texts = entries.select { |entry| entry.is_a?(Hash) }.map { |entry| [entry["language"], entry["value"] || entry["text"]] }
      fits = texts.all? { |language, text| Value.language?(language) && text.is_a?(String) && text.length <= TEXT_LIMIT && !text.empty? }
      element = { "modelType" => fits ? "MultiLanguageProperty" : "SubmodelElementCollection" }
      reference(element, node)
      element["value"] = if fits
                           texts.map { |language, text| { "language" => language, "text" => text } }
                         else
                           named(texts.map { |language, text| [language.to_s, text] })
                         end
      element
    end

    def file(node)
      content_type = node["contentType"].to_s
      content_type = UNKNOWN_TYPE unless CONTENT_TYPE.match?(content_type) && content_type.length <= 128
      element = { "modelType" => "File" }
      reference(element, node)
      title = node["resourceTitle"]
      if title.is_a?(String) && !title.empty?
        language = Value.language?(node["language"]) ? node["language"] : "und"
        element["description"] = [{ "language" => language, "text" => title[0, TEXT_LIMIT] }]
      end
      element["contentType"] = content_type
      element["value"] = node["url"].to_s[0, 2000] if node["url"].is_a?(String) && !node["url"].empty?
      element
    end

    # An object without a known objectType: a container if it has elements, a
    # value if it is an element with one, otherwise a collection of its members.
    def inferred(node, _name)
      if node["elements"].is_a?(Array)
        collection(node)
      elsif node.key?("elementId") && node.key?("value")
        property(node)
      else
        element = { "modelType" => "SubmodelElementCollection" }
        element["value"] = named(node.reject { |key, _| METADATA.include?(key) }.to_a)
        element
      end
    end

    # A plain JSON value of a compressed passport.
    def value_node(value)
      case value
      when Array
        list("value" => value.map { |item| item.is_a?(Hash) ? item : { "objectType" => "SingleValuedDataElement", "value" => item } })
      else
        property("value" => value)
      end
    end

    def reference(element, node)
      ref = node["dictionaryReference"]
      element["semanticId"] = AasView.reference(ref) if ref.is_a?(String) && !ref.empty?
    end
  end

  # The submodels of a published model, filled from the elements of a passport
  # (docs/AAS.md). Per model two files in aas_view/: the structure, extracted
  # from the model (<name>.json, rake dpp:aas:extract_battery_pass), and where
  # the passport's elements go in it (<name>.yml, with the rules in its head).
  class Template
    DIR = File.join(__dir__, "aas_view")

    def self.all
      @all ||= Dir[File.join(DIR, "*.yml")].sort.map { |path| new(path) }
    end

    attr_reader :bindings, :structure

    def initialize(path)
      @bindings = YAML.safe_load(File.read(path))
      @structure = JSON.parse(File.read(path.sub(/\.yml\z/, ".json")))
    end

    def name = "#{@bindings['model']} #{@bindings['version']}"

    def applies?(document) = !find(elements_of(document), @bindings["recognise"]).nil?

    def submodels(document, aas_id)
      return [] unless document.is_a?(Hash) && applies?(document)

      @structure["submodels"].filter_map do |template|
        bindings = @bindings["submodels"][template["idShort"]]
        next if bindings.nil?

        elements = render(template["elements"], data(bindings, document))
        next if elements.none? { |_, data| data }

        { "modelType" => "Submodel", "id" => "#{aas_id}##{template['idShort']}", "idShort" => template["idShort"],
          "kind" => "Instance", "semanticId" => AasView.reference(template["semanticId"]),
          "submodelElements" => elements.map(&:first) }
      end
    end

    # The structure element at an idShort path of a submodel ("a/b[1]/c"), or
    # nil; for checking a table against its model.
    def target(submodel, path)
      node = { "elements" => @structure["submodels"].find { |s| s["idShort"] == submodel }&.fetch("elements", nil) }
      segments(path).each do |segment|
        return nil if node.nil?

        node = if segment.is_a?(Integer)
                 node["item"]
               else
                 Array(node["elements"]).find { |e| e["idShort"] == segment }
               end
      end
      node
    end

    def segments(path)
      path.to_s.split("/").flat_map do |part|
        match = /\A(.+?)\[(\d*)\]\z/.match(part)
        match ? [match[1], match[2].empty? ? 0 : match[2].to_i] : [part]
      end
    end

    private

    # The values the table finds in the passport, as a tree of idShorts and
    # list positions; a leaf is [value, data?], data? false for a constant.
    def data(bindings, document)
      tree = {}
      bindings.each do |target, binding|
        if target.end_with?("[]")
          base = segments(target.delete_suffix("[]"))
          children(find(elements_of(document), binding["each"])).each_with_index do |child, index|
            item = {}
            binding["fields"].each do |field, field_binding|
              leaf = leaf(field_binding, document, child)
              put(item, segments(field), leaf) if leaf
            end
            put(tree, base + [index + 1], item) unless item.empty?
          end
        else
          leaf = leaf(binding, document, nil)
          put(tree, segments(target), leaf) if leaf
        end
      end
      tree
    end

    def leaf(binding, document, child)
      return [binding["value"], false] if binding.key?("value")
      return [document[binding["header"]], true] if binding.key?("header") && !document[binding["header"]].nil?
      return [child["elementId"], true] if binding["element_id"] && child.is_a?(Hash) && child["elementId"]
      return nil unless binding.key?("source")

      scope = child.is_a?(Hash) ? children(child) : elements_of(document)
      node = find(scope, binding["source"])
      return nil unless node.is_a?(Hash) && !node["value"].nil? && !node["value"].is_a?(Hash) && !node["value"].is_a?(Array)
      return nil unless node["unitOfMeasure"] == binding["unit"]

      value = node["value"]
      if binding["values"]
        value = binding["values"][value.to_s]
        return nil if value.nil?
      end
      [value, true]
    end

    def put(tree, keys, leaf)
      *parents, last = keys
      node = parents.reduce(tree) { |current, key| current[key] ||= {} }
      node[last] = leaf
    end

    # [[element, data?], ...] in the order of the model.
    def render(templates, data)
      Array(templates).filter_map do |template|
        value = data[template["idShort"]]
        next if value.nil?

        element, filled = element(template, value)
        next if element.nil?

        [{ "modelType" => element.delete("modelType"), "idShort" => template["idShort"] }.merge(element), filled]
      end
    end

    def element(template, value)
      case template["modelType"]
      when "Property" then property(template, value)
      when "SubmodelElementCollection" then collection(template, value)
      when "SubmodelElementList" then list(template, value)
      end
    end

    def property(template, leaf)
      return nil unless leaf.is_a?(Array)

      text = Value.lexical(leaf.first, template["valueType"])
      return nil if text.nil? || (template["values"] && !template["values"].include?(text))

      element = { "modelType" => "Property" }
      element["semanticId"] = AasView.reference(template["semanticId"]) if template["semanticId"]
      element["valueType"] = template["valueType"]
      element["value"] = text
      [element, leaf.last]
    end

    def collection(template, value)
      return nil unless value.is_a?(Hash)

      children = render(template["elements"], value)
      return nil if children.none? { |_, filled| filled }

      element = { "modelType" => "SubmodelElementCollection" }
      element["semanticId"] = AasView.reference(template["semanticId"]) if template["semanticId"]
      element["value"] = children.map(&:first)
      [element, true]
    end

    def list(template, value)
      return nil unless value.is_a?(Hash) && template["item"]

      item = template["item"]
      items = value.keys.select { |key| key.is_a?(Integer) }.sort.filter_map do |position|
        rendered, filled = element(item, value[position])
        rendered if rendered && filled
      end
      return nil if items.empty?

      element = { "modelType" => "SubmodelElementList" }
      element["semanticId"] = AasView.reference(template["semanticId"]) if template["semanticId"]
      element["semanticIdListElement"] = AasView.reference(item["semanticId"]) if item["semanticId"]
      element["typeValueListElement"] = item["modelType"]
      element["valueTypeListElement"] = item["valueType"] if item["modelType"] == "Property"
      element["value"] = items
      [element, true]
    end

    # The element at an elementId path ("A/B") among +elements+, or nil.
    def find(elements, path)
      return nil if path.nil?

      node = nil
      scope = elements
      path.split("/").each do |id|
        node = Array(scope).find { |element| element.is_a?(Hash) && element["elementId"] == id }
        return nil if node.nil?

        scope = children(node)
      end
      node
    end

    def children(node)
      return [] unless node.is_a?(Hash)
      return node["elements"].select { |e| e.is_a?(Hash) } if node["elements"].is_a?(Array)
      return node["value"].select { |e| e.is_a?(Hash) } if node["value"].is_a?(Array)

      []
    end

    def elements_of(document)
      document.is_a?(Hash) && document["elements"].is_a?(Array) ? document["elements"] : []
    end
  end
end
