# frozen_string_literal: true

require "json"
require "uri"

# Which access class (AccessClass) each attribute of a passport belongs to.
#
# A policy is a document of its own, kept apart from the passport: nothing of it
# goes into the header of EN 18223:2026 Table 1 or into the data elements. It is
# written per product type and names data elements by their path of element
# identifiers, the same path UpdateDataElement takes:
#
#   { "id": "https://example.org/policies/lamp/1",
#     "scheme": "https://w3id.org/soya/dpp-access/v1",
#     "rules": [
#       { "path": "SubstancesOfConcern", "accessClass": "public" },
#       { "path": "SubstancesOfConcern/MaterialComposition", "accessClass": "legitimateInterest" }
#     ] }
#
# How a passport is classified:
#
#   * The header attributes of Table 1 are always public. A rule on one of them
#     is refused when the policy is read.
#   * A data element takes the class of the deepest rule on itself or on one of
#     the collections above it. A rule on a collection therefore covers
#     everything below it that no deeper rule reaches.
#   * The attributes are the header attributes and every data element that is
#     not a collection. The items of a multi-valued or multi-language element
#     belong to that element and share its class; they are not classified one
#     by one.
#   * An attribute no rule reaches gets the policy's +default+, or, without
#     one, the most restrictive class (authority): a value published by
#     mistake cannot be withdrawn, a value withheld by mistake can be released.
#
# The format is described by config/vocab/access-policy.schema.json.
class AccessPolicy
  class InvalidError < StandardError; end

  KEYS      = %w[id title scheme default rules].freeze
  RULE_KEYS = %w[path accessClass].freeze
  HEADER    = ElementIdPath::HEADER_ATTRIBUTES

  # The outcome for one passport: +classes+ maps every attribute to exactly one
  # AccessClass::Concept; +unclassified+ lists the attributes that fell to the
  # default; +unused_rules+ the rule paths that reached no attribute.
  Classification = Struct.new(:classes, :unclassified, :unused_rules, keyword_init: true) do
    def class_of(path) = classes.fetch(path)

    # Attribute paths per class notation, for reading and for the specs.
    def by_class
      AccessClass.all.to_h { |concept| [concept.notation, classes.select { |_, c| c == concept }.keys] }
    end
  end

  attr_reader :id, :title, :default_class, :rules

  def self.parse(json)
    new(json.is_a?(String) ? JSON.parse(json) : json)
  rescue JSON::ParserError => e
    raise InvalidError, "access policy is not JSON (#{e.message})"
  end

  def self.load(path) = parse(File.read(path))

  def initialize(document)
    raise InvalidError, "access policy has to be a JSON object" unless document.is_a?(Hash)

    unknown = document.keys - KEYS
    raise InvalidError, "access policy has unknown members: #{unknown.join(', ')}" if unknown.any?

    @id    = uri(required_string(document, "id"))
    @title = document["title"]
    check_scheme!(document["scheme"])
    @default_class = document.key?("default") ? concept(document["default"], "default") : AccessClass.most_restrictive
    @rules = read_rules(document["rules"])
  end

  # Every attribute of +document+ (the full representation, as stored) with
  # its class.
  def classify(document)
    raise InvalidError, "a passport has to be a JSON object" unless document.is_a?(Hash)

    classes = {}
    unclassified = []
    used = {}

    (document.keys - ["elements"]).each { |name| classes[name] = AccessClass.public_class }

    each_attribute(document["elements"], []) do |segments|
      path = segments.join("/")
      rule = deepest_rule(segments)
      if rule
        used[rule.first] = true
        classes[path] = rule.last
      else
        unclassified << path
        classes[path] = default_class
      end
    end

    Classification.new(classes: classes, unclassified: unclassified,
                       unused_rules: rules.keys - used.keys)
  end

  # +document+ with only the attributes a reader with +roles+ may read
  # (AccessClass.readable_with). The header attributes are public and always
  # stay; a collection stays as long as one of its attributes does. The
  # elements this service adds (PassportSplit::SERVICE_ELEMENTS) are left out.
  def visible_for(roles, document)
    document = PassportSplit.strip(document)
    readable = AccessClass.readable_with(roles)
    classes  = classify(document).classes
    PassportSplit.split(document) { |path| !readable.include?(classes.fetch(path)) }.first
  end

  private

  def required_string(document, key)
    value = document[key]
    return value if value.is_a?(String) && !value.strip.empty?

    raise InvalidError, "access policy needs \"#{key}\" as a non-empty string"
  end

  # An absolute URI, as access-policy.schema.json has it. Printable ASCII only:
  # the id is what a passport refers to the policy by, in an HTTP header.
  def uri(value)
    parsed = URI.parse(value) if value.match?(/\A[!-~]+\z/)
    return value if parsed&.absolute?

    raise InvalidError, "access policy id has to be an absolute URI, got #{value.inspect}"
  rescue URI::InvalidURIError
    raise InvalidError, "access policy id has to be an absolute URI, got #{value.inspect}"
  end

  def check_scheme!(scheme)
    return if scheme == AccessClass::SCHEME

    raise InvalidError, "access policy has to name the scheme #{AccessClass::SCHEME}, got #{scheme.inspect}"
  end

  def concept(value, where)
    AccessClass.resolve(value)
  rescue AccessClass::UnknownError => e
    raise InvalidError, "#{where}: #{e.message}"
  end

  # { "a/b" => Concept }, in the order given.
  def read_rules(list)
    raise InvalidError, "access policy needs \"rules\" as an array" unless list.is_a?(Array)

    list.each_with_index.with_object({}) do |(rule, index), acc|
      where = "rules[#{index}]"
      raise InvalidError, "#{where} has to be an object" unless rule.is_a?(Hash)

      unknown = rule.keys - RULE_KEYS
      raise InvalidError, "#{where} has unknown members: #{unknown.join(', ')}" if unknown.any?

      path = rule["path"]
      unless path.is_a?(String) && !path.empty? && path.split("/", -1).none?(&:empty?)
        raise InvalidError, "#{where}: path has to be element identifiers separated by '/', got #{path.inspect}"
      end
      if HEADER.include?(path.split("/").first)
        raise InvalidError, "#{where}: #{path.inspect} is a header attribute of EN 18223:2026 Table 1, " \
                            "which is always public and cannot be classified"
      end
      raise InvalidError, "#{where}: #{path.inspect} has a rule already" if acc.key?(path)

      acc[path] = concept(rule["accessClass"], where)
    end.freeze
  end

  # [path, concept] of the deepest rule on +segments+ or one of its ancestors.
  def deepest_rule(segments)
    segments.length.downto(1) do |length|
      path = segments.first(length).join("/")
      return [path, rules[path]] if rules.key?(path)
    end
    nil
  end

  # Yields the segments of every attribute below +elements+. A collection is
  # descended into; anything else -- a single value, a list, a related
  # resource -- is one attribute.
  def each_attribute(elements, prefix, &block)
    return unless elements.is_a?(Array)

    elements.each do |element|
      unless element.is_a?(Hash) && element["elementId"].is_a?(String) && !element["elementId"].empty?
        raise InvalidError, "a data element below #{prefix.empty? ? 'the passport' : prefix.join('/')} " \
                            "has no elementId (EN 18223:2026), so it cannot be classified"
      end

      segments = prefix + [element["elementId"]]
      if collection?(element)
        each_attribute(element["elements"], segments, &block)
      else
        yield segments
      end
    end
  end

  def collection?(element) = self.class.collection?(element)

  # A collection is descended into; anything else -- a single value, a list,
  # a related resource -- is one attribute. PassportSplit splits along the
  # same line.
  def self.collection?(element)
    element["elements"].is_a?(Array) && !DppRepresentation::LISTS.include?(element["objectType"])
  end
end
