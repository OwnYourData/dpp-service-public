# frozen_string_literal: true

# The "representation" query flag of EN 18222:2026 8.1 on every method that
# returns a passport or a part of one: "compressed" (the default) or "full".
#
# Read from the query string only. 8.1 calls it a query flag, and a JSON body is
# merged into +params+ by Rails, where a data element named "representation"
# would otherwise be taken for it.
#
# A value other than the two is refused with 400 before the action runs, so a
# CreateDPP with a bad flag mints nothing. The conversion itself is
# DppRepresentation; nothing here knows what the compressed form looks like.
module RepresentationParam
  extend ActiveSupport::Concern

  def representation
    @representation ||= DppRepresentation.parse(request.query_parameters["representation"])
  end

  # before_action; rendering halts the chain.
  def require_valid_representation!
    representation
  rescue DppRepresentation::InvalidError => e
    render_result("ClientErrorBadRequest", text: e.message)
  end

  def render_passport(document, status_code: "Success")
    render_dpp(DppRepresentation.passport(document, representation), status_code: status_code)
  end

  # +document+ is the passport the element was taken from: it decides whether
  # the element is in the full form and has to be converted.
  def render_element(element, document:, status_code: "Success")
    render_dpp(DppRepresentation.element(element, representation, document: document),
               status_code: status_code)
  end
end
