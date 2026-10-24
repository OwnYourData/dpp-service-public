# frozen_string_literal: true

# The path to one data element of a passport: the elementIdPath of
# ReadDataElement and UpdateDataElement (EN 18222:2026 6.2, 6.3, Tables 9, 10
# and 18).
#
# EN 18222:2026 8.1 has elementIdPath follow RFC 9535 (JSONPath). Both methods
# address exactly one element by its absolute path, so the form accepted here is
# the RFC 9535 singular query (2.3.5.1): the root identifier "$" followed by
# name segments and index segments, e.g.
#
#   $.ProductIdentification.ModelIdentifier
#   $['EnergyPerformance']['LuminousFlux']
#   $.EnergyPerformance.efficiencyRatings[0]
#
# A query that is valid JSONPath but can select more than one node (wildcard,
# descendant segment, slice, filter, several selectors in one bracket) is
# refused as NotSingularError; anything that is not RFC 9535 syntax at all as
# InvalidError. Both are bad requests (EN 18222:2026 Table 15).
#
# The names are elementIds, as in the compressed serialization of EN 18223:2026
# 5.2.2, where the elementId is the JSON key. A document stored in the expanded
# form (EN 18223:2026 Annex A) holds its children in "elements" at every level,
# so a name selects the child with that elementId and an index the n-th child;
# a document stored in the compressed form is walked as plain JSON.
#
# A path of element identifiers separated by "/" (EnergyPerformance/LuminousFlux)
# is read as the same sequence of name selectors.
class ElementIdPath
  class InvalidError < StandardError; end
  class NotSingularError < InvalidError; end

  # Header attributes of the DigitalProductPassport class (EN 18223:2026
  # Table 1). They sit next to the data elements in a compressed document but
  # are not data elements, so a name at the top level never selects them.
  HEADER_ATTRIBUTES = %w[digitalProductPassportId uniqueProductIdentifier granularity
                         dppSchemaVersion dppStatus lastUpdated economicOperatorId
                         facilityId contentSpecificationIds].freeze

  # RFC 9535 2.1: integers are limited to the I-JSON range.
  MAX_INT = (2**53) - 1

  BLANK = [" ", "\t", "\n", "\r"].freeze

  ESCAPES = { "b" => "\b", "f" => "\f", "n" => "\n", "r" => "\r", "t" => "\t",
              "/" => "/", "\\" => "\\" }.freeze

  attr_reader :selectors

  def self.parse(raw)
    raw = raw.to_s
    raise InvalidError, "elementIdPath is empty" if raw.empty?

    selectors = raw.start_with?("$") ? Parser.new(raw).parse : raw.split("/", -1).map { |id| [:name, id] }
    new(selectors)
  end

  def initialize(selectors)
    @selectors = selectors.freeze
  end

  # The element identifiers this path names from the top, up to the first
  # index selector: what an access policy can classify without looking at the
  # passport. An index selects by position, which only the passport can say.
  def leading_names
    @selectors.take_while { |kind, _| kind == :name }.map(&:last)
  end

  # The element at this path, or nil.
  def resolve(document)
    container, key = locate(document)
    container && container[key]
  end

  # [container, key] with container[key] being the element, or nil. The
  # container is part of +document+, so assigning to it changes the document.
  # "$" alone designates the passport, which is not a data element.
  def locate(document)
    return nil if @selectors.empty?

    expanded = expanded?(document)
    node = document
    location = nil
    @selectors.each_with_index do |(kind, selector), depth|
      location = expanded ? expanded_step(node, kind, selector) : plain_step(node, kind, selector, depth)
      return nil if location.nil?

      node = location[0][location[1]]
    end
    location
  end

  private

  def expanded?(document)
    document.is_a?(Hash) && document["elements"].is_a?(Array)
  end

  # Expanded form: every level keeps its children in "elements". The items of a
  # multi-valued or multi-language element may sit in "value" instead (EN 18223:2026
  # Annex A, Examples 4 and 6); an index reaches them there as well, so that a path
  # selects the same element here as in the compressed form.
  def expanded_step(node, kind, selector)
    children = expanded_children(node)
    return nil unless children.is_a?(Array)

    index = case kind
            when :name  then children.index { |child| child.is_a?(Hash) && child["elementId"] == selector }
            when :index then normalize_index(selector, children.size)
            end
    index && [children, index]
  end

  def expanded_children(node)
    return nil unless node.is_a?(Hash)
    return node["elements"] if node["elements"].is_a?(Array)

    node["value"] if node["value"].is_a?(Array) && DppRepresentation::LISTS.include?(node["objectType"])
  end

  # Compressed form: the elementId is the key.
  def plain_step(node, kind, selector, depth)
    case kind
    when :name
      return nil unless node.is_a?(Hash) && node.key?(selector)
      return nil if depth.zero? && HEADER_ATTRIBUTES.include?(selector)

      [node, selector]
    when :index
      return nil unless node.is_a?(Array)

      index = normalize_index(selector, node.size)
      index && [node, index]
    end
  end

  # RFC 9535 2.3.3.2: a negative index counts from the end.
  def normalize_index(index, size)
    index += size if index.negative?
    index.between?(0, size - 1) ? index : nil
  end

  # Recursive-descent parser for the singular-query subset of RFC 9535. It
  # recognises the constructs that make a query non-singular only as far as
  # needed to say so.
  class Parser
    def initialize(raw)
      @raw = raw
      @pos = 0
    end

    def parse
      expect("$")
      selectors = []
      loop do
        blank_start = @pos
        skip_blank
        if eof?
          invalid("blank space after the last segment") if @pos > blank_start
          return selectors
        end

        case peek
        when "." then selectors << dot_segment
        when "[" then selectors << bracket_segment
        else invalid("unexpected #{peek.inspect}")
        end
      end
    end

    private

    # "." member-name-shorthand; ".*" and ".." are not singular.
    def dot_segment
      expect(".")
      not_singular("descendant segments ('..')") if peek == "."
      not_singular("wildcard selectors ('*')") if peek == "*"
      [:name, member_name_shorthand]
    end

    # "[" S selector S "]" with a name or an index selector.
    def bracket_segment
      expect("[")
      skip_blank
      selector =
        case peek
        when "'", '"' then [:name, string_literal]
        when "*"      then not_singular("wildcard selectors ('*')")
        when "?"      then not_singular("filter selectors ('?')")
        when ":"      then not_singular("slice selectors (':')")
        when "-", /\d/ then [:index, integer]
        else invalid(eof? ? "unterminated bracket" : "unexpected #{peek.inspect} in brackets")
        end
      skip_blank
      not_singular("slice selectors (':')") if peek == ":" && selector[0] == :index
      not_singular("more than one selector in brackets") if peek == ","
      expect("]")
      selector
    end

    # name-first = ALPHA / "_" / %x80-D7FF / %xE000-10FFFF; name-char adds DIGIT.
    def member_name_shorthand
      start = @pos
      invalid("expected a member name after '.'") unless name_first?(peek)
      @pos += 1
      @pos += 1 while !eof? && (name_first?(peek) || peek.match?(/\A[0-9]\z/))
      @raw[start...@pos]
    end

    def name_first?(char)
      return false if char.nil?

      code = char.ord
      char.match?(/\A[A-Za-z_]\z/) || (0x80..0xD7FF).cover?(code) || (0xE000..0x10FFFF).cover?(code)
    end

    # int = "0" / (["-"] DIGIT1 *DIGIT), within the I-JSON range.
    def integer
      start = @pos
      @pos += 1 if peek == "-"
      digits_start = @pos
      @pos += 1 while !eof? && peek.match?(/\A[0-9]\z/)
      text = @raw[start...@pos]
      digits = @raw[digits_start...@pos]
      invalid("expected an integer") if digits.empty?
      invalid("leading zeros or -0 in #{text.inspect}") if digits.length > 1 && digits.start_with?("0")
      invalid("-0 is not an index") if text == "-0"

      value = Integer(text, 10)
      invalid("index #{text} outside the I-JSON range") if value.abs > MAX_INT
      value
    end

    # RFC 9535 2.3.1.1: single- or double-quoted, with JSON-like escapes.
    def string_literal
      quote = peek
      @pos += 1
      out = +""
      loop do
        invalid("unterminated string") if eof?
        char = peek
        @pos += 1
        return out if char == quote

        if char == "\\"
          out << escape(quote)
        elsif char.ord < 0x20
          invalid("control character in a string")
        else
          out << char
        end
      end
    end

    def escape(quote)
      invalid("unterminated escape") if eof?
      char = peek
      @pos += 1
      return quote if char == quote
      return ESCAPES.fetch(char) if ESCAPES.key?(char)
      return unicode_escape if char == "u"

      invalid("invalid escape \\#{char}")
    end

    def unicode_escape
      high = hex4
      invalid("lone low surrogate") if (0xDC00..0xDFFF).cover?(high)
      return [high].pack("U") unless (0xD800..0xDBFF).cover?(high)

      invalid("high surrogate without a low one") unless @raw[@pos, 2] == "\\u"
      @pos += 2
      low = hex4
      invalid("high surrogate without a low one") unless (0xDC00..0xDFFF).cover?(low)
      [0x10000 + ((high - 0xD800) << 10) + (low - 0xDC00)].pack("U")
    end

    def hex4
      text = @raw[@pos, 4].to_s
      invalid("expected four hex digits after \\u") unless text.match?(/\A\h{4}\z/)
      @pos += 4
      text.to_i(16)
    end

    def skip_blank
      @pos += 1 while !eof? && BLANK.include?(peek)
    end

    def expect(char)
      invalid(eof? ? "expected #{char.inspect} at the end" : "expected #{char.inspect}, found #{peek.inspect}") unless peek == char
      @pos += 1
    end

    def peek = @raw[@pos]
    def eof? = @pos >= @raw.length

    def invalid(reason)
      raise InvalidError, "not an RFC 9535 JSONPath query (#{reason} at position #{@pos})"
    end

    def not_singular(what)
      raise NotSingularError,
            "#{what} can select more than one node; elementIdPath must designate one data element " \
            "(an RFC 9535 singular query: names and indexes only)"
    end
  end
end
