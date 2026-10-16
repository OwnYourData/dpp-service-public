# frozen_string_literal: true

require "uri"

# The two representations of a passport a client chooses between with the
# "representation" query flag of EN 18222:2026 8.1, and the one conversion
# between them.
#
#   full        the expanded serialization of EN 18223:2026 Annex A: the header
#               attributes of Table 1, then the data elements in "elements",
#               each an object carrying its metadata (elementId, objectType,
#               dictionaryReference, valueDataType) and, for a container, its
#               children in "elements" again. Passports are stored in this form,
#               and a custodian serves it.
#   compressed  the serialization of EN 18223:2026 5.2: the header attributes as
#               they are, every data element as a member of the passport object
#               under its elementId (5.2.2), without the metadata a data
#               dictionary carries, each class in its plain JSON shape
#               (5.2.5 to 5.2.9). The default when the flag is absent (8.1).
#
# Only full -> compressed exists. The compressed form leaves out what a
# dictionary holds, so there is no way back, and none is needed: documents are
# kept full and converted on the way out. A document that was stored without
# "elements" is already compressed and is returned as it is in both cases.
#
# Plain Ruby, no Rails: pod-dpp serves the same EN 18222 read paths and carries
# a copy of this file and of ElementIdPath. Both are held to the vectors in
# spec/fixtures/representation-vectors, which pod-dpp runs as well.
module DppRepresentation
  FULL       = "full"
  COMPRESSED = "compressed"
  VALUES     = [COMPRESSED, FULL].freeze
  DEFAULT    = COMPRESSED

  class InvalidError < StandardError; end

  # Element metadata that 5.2.2 leaves to the data dictionary, plus the two keys
  # the expanded form needs to say which element an object is and of what class.
  METADATA = %w[elementId objectType dictionaryReference valueDataType].freeze

  # The classes whose items are listed rather than named. Annex A shows the items
  # of a multi-valued element both in "elements" (Example 1) and in "value"
  # (Example 4); both are read.
  LISTS = %w[MultiValuedDataElement MultiLanguageDataElement].freeze

  module_function

  # The flag as the client sent it, or the default when it sent none. 8.1 names
  # exactly two values, so anything else -- another spelling of them included --
  # is refused rather than guessed at.
  def parse(raw)
    return DEFAULT if raw.nil?
    return raw if raw.is_a?(String) && VALUES.include?(raw)

    raise InvalidError,
          "representation has to be \"compressed\" or \"full\" (EN 18222:2026 8.1), " \
          "got #{raw.is_a?(String) ? raw.inspect : 'a structured value'}"
  end

  # A whole passport in the requested representation.
  def passport(document, representation)
    representation == FULL ? document : compress_document(document)
  end

  # One element of +document+ in the requested representation. The element is
  # converted only if the document it came from is in the full form; out of a
  # compressed document it already is what the compressed form says it is.
  def element(element, representation, document:)
    return element if representation == FULL || !full?(document)

    compress_element(element)
  end

  # +url+ with representation=full in its query, replacing any other value. For
  # the parties that need the stored form from an EN 18222 read path: the
  # payload commitment binds the full representation (docs/Integrity.md
  # section 4), and a serviceEndpoint names the resource, not a representation.
  def full_url(url)
    uri = URI.parse(url.to_s)
    query = URI.decode_www_form(uri.query.to_s).reject { |key, _| key == "representation" }
    uri.query = URI.encode_www_form(query + [["representation", FULL]])
    uri.to_s
  end

  def full?(document)
    document.is_a?(Hash) && document["elements"].is_a?(Array)
  end

  # 5.2.4: one JSON object, the header first, then the data elements under their
  # elementIds. A header attribute keeps its place if an element carries the
  # same name; ElementIdPath never selects such a name at the top level either.
  def compress_document(document)
    return document unless full?(document)

    header = document.except("elements")
    header.merge(compress_members(document["elements"]).except(*header.keys))
  end

  # One data element in its compressed shape -- the value it has under its
  # elementId in the compressed passport.
  def compress_element(element)
    return element unless element.is_a?(Hash)

    case element["objectType"]
    when "DataElementCollection"    then compress_members(children(element))         # 5.2.5
    when "SingleValuedDataElement"  then element["value"]                             # 5.2.6
    when "MultiValuedDataElement"   then children(element).map { |item| compress_element(item) } # 5.2.7
    when "MultiLanguageDataElement" then children(element)                            # 5.2.9
    when "RelatedResource"          then element.except(*METADATA)                    # 5.2.8
    else infer(element)
    end
  end

  # Children of a container, keyed by their elementId (5.2.2). Table 2 makes the
  # elementId mandatory and unique within its level; a child without one has no
  # key in the compressed form and is left out.
  def compress_members(children)
    Array(children).each_with_object({}) do |child, members|
      next unless child.is_a?(Hash) && child["elementId"].is_a?(String)

      members[child["elementId"]] = compress_element(child)
    end
  end

  def children(element)
    return element["elements"] if element["elements"].is_a?(Array)
    return element["value"] if element["value"].is_a?(Array) && LISTS.include?(element["objectType"])

    []
  end

  # An object without an objectType: a container if it has children, a value if
  # it is an element with one, otherwise an object of its own (a related
  # resource, a MultiLanguageValue) without the dictionary metadata.
  def infer(element)
    return compress_members(element["elements"]) if element["elements"].is_a?(Array)
    return element["value"] if element.key?("elementId") && element.key?("value")

    element.except(*METADATA)
  end
end
