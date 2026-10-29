# frozen_string_literal: true

# The X-DPP-Warning header on a write of the owner: what the passport, as it
# now stands, should carry and does not. Nothing in it stops a write; the
# passport is stored as sent.
#
# An RFC 8941 list, one item per finding, the code as token and the element as
# its parameter:
#
#   X-DPP-Warning: missingContentType;element="$.DeclarationOfConformity"
#
#   missingContentType   a RelatedResource without contentType
#                        (EN 18223:2026 Table 5; RelatedResourceCheck)
#
# At most LIMIT items; when there are more, the last item carries
# more=<number left out>. Characters outside printable ASCII in an
# element path are percent-encoded, as in the URL of the element. Without
# findings the header is absent. Read paths never carry it.
module WriteWarnings
  extend ActiveSupport::Concern

  WARNING_HEADER = "X-DPP-Warning"
  LIMIT = 20

  def report_write_warnings(dpp)
    paths = RelatedResourceCheck.missing_content_type(dpp.to_document)
    return if paths.empty?

    items = paths.first(LIMIT).map { |path| "missingContentType;element=#{warning_string(path)}" }
    items[-1] = "#{items[-1]};more=#{paths.size - LIMIT}" if paths.size > LIMIT
    response.set_header(WARNING_HEADER, items.join(", "))
  end

  private

  # RFC 8941 3.3.3 strings hold printable ASCII only.
  def warning_string(value)
    ascii = value.gsub(/[^\x20-\x7E]/) { |char| char.bytes.map { |byte| format("%%%02X", byte) }.join }
    "\"#{ascii.gsub(/[\\"]/) { |c| "\\#{c}" }}\""
  end
end
