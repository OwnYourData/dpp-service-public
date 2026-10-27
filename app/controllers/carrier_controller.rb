# frozen_string_literal: true

# The carrier path: what a data carrier bears, answered on the hosts in
# DPP_CARRIER_HOSTS (CarrierHosts, docs/Identifiers.md section 3).
#
# The unique product identifier is one string that identifies the product and
# leads to its passport (EN 18219:2026 3.1.25), and the carrier bears exactly
# that string (4.5.2 (1)). A request for https://<carrier host><path> is
# therefore a lookup of the passport whose uniqueProductIdentifier is that
# address: the same lookup as ReadDPPByProductId, so it finds a passport in
# this service's database and one this service keeps at a custodian alike.
#
# One address, three answers, by content negotiation (RFC 9110 12.5.1):
#
#   * JSON, the format EN 18216:2026 clause 5 requires -- without Accept, for
#     */*, and whenever JSON is weighted at least as high as HTML;
#   * HTML for a browser, which asks for text/html with a lead (PassportHtml);
#   * the signature of the economic operator for application/jose, exactly
#     where the read paths hand it out (OperatorSignatureDelivery).
#
# The representation defaults to "full" here, as on the carrier path of the
# custodian's pod, so that a carrier host can move between the two without a
# reader noticing; ?representation=compressed gives the other form. The API
# keeps its default of EN 18222:2026 8.1.
#
# Access is that of the read paths: the public part without a token, more for
# the owner and for a reader with access rights who presents one, with the
# same headers and the same entries in the access log.
#
# A carrier host serves nothing else. What is recognisably an address of the
# API rather than an identifier is answered with 404 and says where the API is,
# so that a client looking for the API here does not conclude that a passport
# does not exist.
class CarrierController < ApplicationController
  # First path segments that belong to the API host, never to an identifier.
  API_SEGMENTS = %w[dpp api-docs .well-known up version].freeze

  HTML = "text/html"
  JSON_TYPE = "application/json"

  before_action :refuse_api_path, only: :show
  before_action :require_valid_representation!, only: :show
  before_action :authenticate_reader!, only: :show

  # GET / on a carrier host
  def index
    send_html(PassportHtml.host_page(api_base: api_base))
  end

  # GET, HEAD <identifier path>
  def show
    dpp = passport_for_request
    return not_found if dpp.nil?

    result = PassportAccess.current(dpp, reader: reader_did)
    report_commitment(dpp)
    report_access(result)
    return render_passport_or_signature(dpp, result.document) unless html_preferred?

    vary_on_accept!
    report_signature(dpp)
    full = DppRepresentation.passport(result.document, DppRepresentation::FULL)
    send_html(PassportHtml.render(full, url: request.original_url))
  end

  # Anything but GET and HEAD
  def refuse
    response.set_header("Allow", "GET, HEAD")
    render_result("ClientMethodNotAllowed",
                  text: "This host answers product identifiers with GET only; the API is at #{api_base}")
  end

  private

  # ?representation=full unless the request says otherwise.
  def representation
    @representation ||= DppRepresentation.parse(
      request.query_parameters.fetch("representation", DppRepresentation::FULL)
    )
  end

  def passport_for_request
    identifier = ProductIdentifier.parse!("https://#{request.host.downcase}#{request.path}")
    Dpp.active.where(product_key: identifier.product_key, product_host: identifier.host.downcase)
       .order(last_update: :desc).first
  rescue ProductIdentifier::InvalidError
    nil
  end

  def refuse_api_path
    first = request.path.split("/").reject(&:empty?).first.to_s
    return unless API_SEGMENTS.include?(first)

    render_result("ClientErrorResourceNotFound",
                  text: "This host answers product identifiers only; the API is at #{api_base}")
  end

  def not_found
    render_result("ClientErrorResourceNotFound", text: "No passport for this product identifier")
  end

  # HTML only with a real lead over JSON and over the signature: a client
  # that weighs them alike, or names neither, keeps receiving JSON.
  def html_preferred?
    ranges = parse_accept(request.headers["Accept"])
    return false if ranges.empty?

    html = quality(ranges, HTML)
    html.positive? && html > quality(ranges, JSON_TYPE) && html > quality(ranges, OperatorSignature::MEDIA_TYPE)
  end

  def send_html(html)
    response.set_header("Content-Security-Policy", PassportHtml::SECURITY_POLICY)
    render body: html, content_type: "text/html; charset=utf-8"
  end

  def api_base = DidOyd.endpoint_base.delete_suffix("/")
end
