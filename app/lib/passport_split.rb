# frozen_string_literal: true

require "json"
require "securerandom"
require "json/canonicalization"

# Splitting a passport into the part a custodian publishes and the part it
# only hands out to readers with a right to it, and putting the two back
# together (docs/AccessClasses.md).
#
# A custodian that holds controlled cards keeps a passport with an access
# policy as two cards in the same collection, with the same
# digitalProductPassportId and uniqueProductIdentifier:
#
#   DigitalProductPassport            the public attributes; its public paths
#                                     serve this card and no other
#   DigitalProductPassportControlled  every other attribute, legitimateInterest
#                                     and authority alike
#
# Both payloads carry the full header of EN 18223:2026 Table 1, unchanged, and
# in +elements+ only their own attributes. A collection whose children fall on
# both sides appears in both, each time with its own metadata and its own
# children. An attribute is what AccessPolicy classifies: a data element that
# is not a collection; the items of a list travel with their list.
#
# The public payload names the controlled one in a data element of its own,
#
#   { "elementId": "ControlledData", "objectType": "SingleValuedDataElement",
#     "valueDataType": "xsd:string", "value": "<sha2-256, multibase>" }
#
# the hash of the controlled payload in its JSON canonicalization (RFC 8785).
# The controlled payload carries a random salt in "ControlledDataSalt", so the
# hash says nothing about values with few possibilities. Whatever commits to
# the public bytes -- the DID document (docs/Integrity.md) -- thereby commits
# to the controlled part as well. Both elements belong to this service: they
# are taken out again when the two parts are put together, and a passport
# cannot set them itself.
module PassportSplit
  DIGEST_ELEMENT = "ControlledData"
  SALT_ELEMENT   = "ControlledDataSalt"
  SERVICE_ELEMENTS = [DIGEST_ELEMENT, SALT_ELEMENT].freeze

  module_function

  # [public, controlled] for +document+ (the whole passport, without service
  # elements). +controlled+ is a predicate on attribute paths ("A/B").
  def split(document, &controlled)
    hull = document.except("elements")
    pub, ctl = split_elements(Array(document["elements"]), [], controlled)
    public_doc = document.key?("elements") ? hull.merge("elements" => pub) : hull.dup
    [public_doc, hull.merge("elements" => ctl)]
  end

  # The whole passport from its two parts. The header comes from the public
  # part. Elements are joined by elementId, level by level: the public ones in
  # their order, then the controlled ones that are not there. An attribute in
  # both parts -- possible only after a write that broke off -- is taken from
  # the controlled part, which is always written first.
  def merge(public_doc, controlled_doc)
    pub = strip(public_doc || {})
    ctl = strip(controlled_doc || {})
    elements = merge_elements(Array(pub["elements"]), Array(ctl["elements"]))
    return pub if elements.empty? && !pub.key?("elements")

    pub.merge("elements" => elements)
  end

  # +document+ without the elements this service adds.
  def strip(document)
    return document unless document.is_a?(Hash) && document["elements"].is_a?(Array)

    document.merge("elements" => document["elements"].reject { |e| service_element?(e) })
  end

  def service_element?(element)
    element.is_a?(Hash) && SERVICE_ELEMENTS.include?(element["elementId"])
  end

  # The digest a public payload names, or nil.
  def named_digest(public_doc)
    element = Array(public_doc.is_a?(Hash) ? public_doc["elements"] : nil)
              .find { |e| e.is_a?(Hash) && e["elementId"] == DIGEST_ELEMENT }
    element && element["value"]
  end

  # The controlled payload as it is written: the controlled part with a fresh
  # salt.
  def controlled_payload(controlled_doc)
    controlled_doc.merge("elements" => Array(controlled_doc["elements"]) + [salt_element])
  end

  # The public payload as it is written: the public part naming +payload+.
  def public_payload(public_doc, controlled_payload)
    public_doc.merge("elements" => Array(public_doc["elements"]) + [digest_element(digest(controlled_payload))])
  end

  # sha2-256 over the RFC 8785 form, in the encoding of the payload hash.
  def digest(controlled_payload)
    PayloadCommitment.digest(controlled_payload.to_json_c14n)
  end

  # Every attribute path below +document+.
  def attribute_paths(document)
    paths = []
    each_attribute(Array(strip(document || {})["elements"]), []) { |segments| paths << segments.join("/") }
    paths
  end

  # --- internals ---------------------------------------------------------

  def split_elements(elements, prefix, controlled)
    pub = []
    ctl = []
    elements.each do |element|
      next if prefix.empty? && service_element?(element)

      segments = prefix + [element["elementId"].to_s]
      if AccessPolicy.collection?(element)
        sub_pub, sub_ctl = split_elements(element["elements"], segments, controlled)
        if sub_ctl.empty?
          pub << element
        elsif sub_pub.empty?
          ctl << element
        else
          pub << element.merge("elements" => sub_pub)
          ctl << element.merge("elements" => sub_ctl)
        end
      elsif controlled.call(segments.join("/"))
        ctl << element
      else
        pub << element
      end
    end
    [pub, ctl]
  end

  def merge_elements(public_elements, controlled_elements)
    out = public_elements.map(&:dup)
    controlled_elements.each do |element|
      index = out.index { |e| e.is_a?(Hash) && e["elementId"] == element["elementId"] }
      if index.nil?
        out << element
      elsif AccessPolicy.collection?(out[index]) && AccessPolicy.collection?(element)
        out[index] = out[index].merge(element.except("elements"))
                               .merge("elements" => merge_elements(out[index]["elements"], element["elements"]))
      else
        out[index] = element
      end
    end
    out
  end

  def each_attribute(elements, prefix, &block)
    elements.each do |element|
      next unless element.is_a?(Hash)

      segments = prefix + [element["elementId"].to_s]
      if AccessPolicy.collection?(element)
        each_attribute(element["elements"], segments, &block)
      else
        yield segments
      end
    end
  end

  def salt_element
    { "elementId" => SALT_ELEMENT, "objectType" => "SingleValuedDataElement",
      "valueDataType" => "xsd:string", "value" => SecureRandom.urlsafe_base64(16, false) }
  end

  def digest_element(value)
    { "elementId" => DIGEST_ELEMENT, "objectType" => "SingleValuedDataElement",
      "valueDataType" => "xsd:string", "value" => value }
  end

  private_class_method :split_elements, :merge_elements, :each_attribute, :salt_element, :digest_element
end
