# frozen_string_literal: true

require "uri"

# A ProductID, which is at the same time the Unique Product Identifier borne by
# the data carrier.
#
# prEN 18219 §3.22 defines the unique product identifier as *one* string of
# characters that identifies the product and "also enables a web link to the
# digital product passport". §4.5.2 (1) then requires that very string to be
# retrievable from the data carrier. There is therefore no second, separate
# carrier token: ProductID and UPI are the same value.
#
#   ProductID = UPI = https://dpp.oydapp.eu/01/09520123456791/21/000123
#   product_key                            /01/09520123456791/21/000123
#
# The +product_key+ is the host-independent remainder. It is the lookup key in
# the custodian's store, which is what allows one store to serve any number of
# operator-owned hostnames pointed at it by CNAME.
#
# == Two admissible schemes
#
# prEN 18219 Section 5 lists the permitted schemes exhaustively. Two of them can
# be borne by a carrier as an https URL, and they differ in who issues:
#
# [§5.1.2.1 +:digital_link+]
#   A structured path of GS1 application identifiers (ISO/IEC 18975, GS1 Digital
#   Link). The GTIN prefix comes from an issuing agency registered under
#   ISO/IEC 15459-2 -- in practice a GS1 member organisation, which licenses the
#   prefix annually. Granularity is expressed by the path and is therefore
#   checked rather than believed.
#
# [§5.2 +:identification_link+]
#   An identification link per EN IEC 61406-1, which §5.2.1 calls a
#   "self-issuing system" that "eliminates external dependencies": the operator
#   needs a domain it controls and nothing else. The path is opaque by design,
#   so granularity cannot be derived from it and has to be taken from the
#   declaration.
#
# Supporting only the first would tie every economic operator to a paid annual
# membership -- an odd position for an architecture whose argument is the
# absence of lock-in. Which scheme applies is decided by the path: a leading
# application identifier means the Digital Link rules apply in full.
#
# A DID cannot be borne here, though §5.3 admits it as a scheme: §3.16 note 1
# records that DID resolution normally requires additional software, and
# §4.6.2 (2) forbids the consumer path from demanding any. See
# docs/Identifiers.md for the character budget that settles it.
class ProductIdentifier
  class InvalidError < StandardError; end

  # DPP Registry User Guide for Economic Operators (DG GROW): "The UPI is a
  # mandatory value conforming to a URL format compliant with JTC 24 standards.
  # Max length is 50 chars." The https requirement has the same source ("Enter a
  # URL starting with https://"). Checked 2026-08: Implementing Regulation (EU)
  # 2026/1778 sets no length and no scheme constraint - the words character,
  # length, https and URL do not occur in it. This is a registry implementation
  # rule, not a legal one, and can change without a change in the law.
  MAX_LENGTH = 50

  DIGITAL_LINK        = :digital_link
  IDENTIFICATION_LINK = :identification_link

  # Application identifiers we accept in a Digital Link. Deliberately a short
  # list: every entry is a value a carrier may legitimately bear, and anything
  # else is more likely a mistake than an intention.
  PRIMARY_AI = "01" # GTIN-14
  QUALIFIER_AIS = {
    "10" => :batch,  # batch or lot number
    "21" => :item,   # serial number
    "22" => :model   # consumer product variant
  }.freeze

  # GS1 Digital Link canonical form. Shorter GTIN representations (8, 12, 13)
  # are deliberately rejected rather than zero-padded here: the same value has
  # to be reconstructed byte-for-byte by the custodian from the request path,
  # and duplicating a normalisation rule across two codebases is how the two
  # drift apart. One spelling, checked at the only place that writes it.
  GTIN_PATTERN = /\A\d{14}\z/
  AI_PATTERN   = /\A\d{2,4}\z/
  # Reserved characters would have to be percent-encoded and would then no
  # longer match the stored key; neither GS1 element strings nor EN IEC 61406
  # identification links need them.
  VALUE_PATTERN = %r{\A[A-Za-z0-9\-_.]{1,20}\z}
  SEGMENT_PATTERN = %r{\A[A-Za-z0-9\-_.]{1,48}\z}

  attr_reader :value, :host, :product_key, :scheme, :gtin, :qualifiers

  # Parse and validate, or raise InvalidError with a message meant for the
  # client (it becomes the text of a ClientErrorBadRequest).
  def self.parse!(value)
    new(value).tap(&:validate!)
  end

  # True when +value+ can serve as a carrier-borne identifier at all.
  def self.valid?(value)
    parse!(value)
    true
  rescue InvalidError
    false
  end

  def initialize(value)
    @value = value.to_s.strip
    @uri = begin
      URI.parse(@value)
    rescue URI::InvalidURIError
      nil
    end
    @host = @uri&.host
    @scheme = nil
    @qualifiers = nil
    @product_key = build_product_key
    @gtin = @qualifiers && @qualifiers[PRIMARY_AI]
  end

  # "model" | "batch" | "item" for a Digital Link, nil for an identification
  # link, whose path says nothing about granularity.
  #
  # prEN 18223 Table 1 requires Granularity to state "the level of granularity
  # of the ProductID as per ESPR". Where the path expresses it, the declared
  # value can be checked instead of trusted; where it does not, the declaration
  # is all there is.
  def granularity
    return nil unless scheme == DIGITAL_LINK
    return "item"  if qualifiers.key?("21")
    return "batch" if qualifiers.key?("10")

    "model"
  end

  # The carrier string is the identifier itself, so its length is the budget.
  def length
    value.length
  end

  def validate!
    raise InvalidError, "ProductID must be a valid URL" if @uri.nil? || host.nil? || host.empty?

    unless value.start_with?("https://")
      raise InvalidError, "ProductID must use https (DPP Registry User Guide; prEN 18216 §6.2)"
    end

    if length > MAX_LENGTH
      raise InvalidError,
            "ProductID is #{length} characters, #{length - MAX_LENGTH} over the " \
            "#{MAX_LENGTH}-character limit of the EU DPP registry; a shorter host " \
            "or a shorter serial is needed"
    end

    # A query string would hold GS1 data attributes, not identity. Allowing it
    # would let two ProductIDs share one product_key and collide in the store,
    # so the identifier stays path-only; data attributes belong in the DPP
    # document.
    if @uri.query || @uri.fragment
      raise InvalidError, "ProductID must not carry a query string or fragment"
    end

    if product_key.nil?
      raise InvalidError, invalid_path_message
    end

    self
  end

  # Raise unless the declared Granularity is consistent with the identifier.
  #
  # For a Digital Link the path decides. For an identification link there is
  # nothing to compare against, so all that can be required is that a value was
  # declared at all -- which prEN 18223 Table 1 makes mandatory anyway.
  def assert_granularity!(declared)
    declared = declared.to_s

    if scheme == IDENTIFICATION_LINK
      return self unless declared.empty?

      raise InvalidError,
            "Granularity is required: an identification link (prEN 18219 §5.2) " \
            "carries an opaque path, so it cannot be derived from the ProductID"
    end

    return self if declared.empty? || declared == granularity

    raise InvalidError,
          "Granularity '#{declared}' contradicts the ProductID path, which " \
          "expresses '#{granularity}' (prEN 18223 Table 1)"
  end

  private

  # The path decides which scheme applies: a leading application identifier
  # means the Digital Link rules apply in full, so a malformed GTIN cannot slip
  # through by being treated as free text. Returns nil for anything neither
  # scheme accepts.
  #
  # The query string is left out on purpose -- GS1 carries non-identifying data
  # attributes there (prEN 18219 Table B.7 shows "?17=250101"), and those must
  # not become part of the lookup key.
  def build_product_key
    path = @uri&.path.to_s.chomp("/")
    return nil if path.empty?

    segments = path.delete_prefix("/").split("/")
    return nil if segments.empty?

    if AI_PATTERN.match?(segments.first.to_s)
      @scheme = DIGITAL_LINK
      digital_link_key(segments, path)
    else
      @scheme = IDENTIFICATION_LINK
      identification_link_key(segments, path)
    end
  end

  # prEN 18219 §5.1.2.1: /01/<GTIN-14> plus at most one of each accepted
  # qualifier.
  def digital_link_key(segments, path)
    return nil unless segments.length.even? && segments.length >= 2

    pairs = segments.each_slice(2).to_a
    ai, gtin = pairs.first
    return nil unless ai == PRIMARY_AI && gtin.match?(GTIN_PATTERN)

    seen = { PRIMARY_AI => gtin }
    pairs.drop(1).each do |qualifier_ai, qualifier_value|
      return nil unless QUALIFIER_AIS.key?(qualifier_ai)
      return nil if seen.key?(qualifier_ai) # each AI at most once
      return nil unless VALUE_PATTERN.match?(qualifier_value.to_s)

      seen[qualifier_ai] = qualifier_value
    end

    @qualifiers = seen
    path
  end

  # prEN 18219 §5.2 / EN IEC 61406-1: the operator's own domain and a path it
  # assigns itself. Nothing about the path is interpreted here -- that is the
  # point of a self-issuing scheme -- so only the character set is constrained,
  # to what survives a carrier and a URL path segment unencoded. Conformance
  # with EN IEC 61406-1 itself (and with §5.2.4 for model or batch level) rests
  # with the operator; it is not checkable from the string alone.
  def identification_link_key(segments, path)
    return nil unless segments.all? { |seg| SEGMENT_PATTERN.match?(seg) }

    path
  end

  def invalid_path_message
    if @scheme == DIGITAL_LINK
      "ProductID starts with an application identifier, so it is read as a GS1 " \
        "Digital Link (prEN 18219 §5.1.2.1) and must be /01/<14-digit GTIN> " \
        "optionally followed by /10/<batch>, /21/<serial> or /22/<variant>"
    else
      "ProductID path must be either a GS1 Digital Link (prEN 18219 §5.1.2.1) " \
        "or an identification link under a domain you control " \
        "(prEN 18219 §5.2, EN IEC 61406-1), using only letters, digits, " \
        "'-', '_' and '.' in its path segments"
    end
  end
end
