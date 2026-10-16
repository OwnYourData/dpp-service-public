# frozen_string_literal: true

# An economic operator identifier as EN 18223:2026 Table 1 asks for it:
# "String formatted according to EN 18219:2026". Clause 6 of EN 18219 gives
# four ID schemes for economic operators, and an identifier has to follow one:
#
#   scheme 6  ISO/IEC 6523 -- a four-digit ICD, a colon, and the identifier
#             the scheme with that ICD issues (0199:<LEI>, 0223:<EU VAT>,
#             0088:<GLN>, 0060:<DUNS>)
#   scheme 7  ISO/IEC 15418 in a data system -- a web address, as a GS1
#             Digital Link or an EN IEC 61406-2 URL constructs it
#   scheme 8  a DID (W3C DID v1.0 syntax)
#   scheme 9  a DOI, bare or as a doi: URI; https://doi.org/... is a web
#             address and passes as such
#
# What is checked is the form. Whether the identifier exists is not: an LEI
# is not looked up at GLEIF and a DID is not resolved here.
module OperatorIdentifier
  DID = /\Adid:[a-z0-9]+:[[:graph:]]+\z/
  DOI = /\A(?:doi:)?10\.\d{4,9}\/[[:graph:]]+\z/i
  ICD = /\A\d{4}:[[:graph:]]+\z/

  REFUSAL = "economicOperatorId has to follow one of the ID schemes of EN 18219:2026 Clause 6: " \
            "a DID (did:...), an ISO/IEC 6523 identifier (ICD:identifier, e.g. 0199:<LEI>), " \
            "a web address (https://...) or a DOI (10.<registrant>/<suffix>)"

  module_function

  # The EN 18219 scheme number the value is formed after, or nil.
  def scheme(value)
    string = value.to_s
    return nil if string.empty? || string.match?(/\s/)
    return 8 if string.match?(DID)
    return 9 if string.match?(DOI)
    return 6 if string.match?(ICD)
    return 7 if web_address?(string)

    nil
  end

  def valid?(value) = !scheme(value).nil?

  def web_address?(string)
    uri = URI.parse(string)
    uri.is_a?(URI::HTTPS) && uri.host.present?
  rescue URI::InvalidURIError
    false
  end
end
