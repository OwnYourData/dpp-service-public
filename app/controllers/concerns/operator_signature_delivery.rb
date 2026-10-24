# frozen_string_literal: true

# Reports and delivers the signature of the economic operator
# (docs/Integrity.md section 10).
#
#   X-DPP-Signature-State   none | pending | signed | stale
#
# on ReadDPPById, ReadDPPByProductId and every write that answers with the
# passport. A header and not a field of the document, for the reason the
# commitment state is one (PayloadIntegrity): EN 18223:2026 Table 1 leaves no
# room for it in the passport.
#
# With Accept preferring application/jose over application/json, the two read
# paths answer with the JWS itself -- but only when its payload is exactly the
# JSON the same request would get, which in practice means the full
# representation and no access class applied. Otherwise they answer with that
# JSON, as without the Accept header. A verifier that compares the signature
# with the JSON answer to the same request can therefore never find the two
# apart, whoever asks and in which representation.
module OperatorSignatureDelivery
  extend ActiveSupport::Concern

  SIGNATURE_STATE_HEADER = "X-DPP-Signature-State"

  # On a read or after a write: check the signature if it is due (refresh),
  # then say which state it is in.
  def report_signature(dpp)
    return if dpp.nil? || dpp.destroyed?

    OperatorSignature.refresh(dpp)
    response.set_header(SIGNATURE_STATE_HEADER, OperatorSignature.state(dpp))
  end

  # The answer of a read path: the JWS where it may be handed out, the
  # passport in the requested representation otherwise.
  def render_passport_or_signature(dpp, document)
    vary_on_accept!
    report_signature(dpp)

    representation_document = DppRepresentation.passport(document, representation)
    compact = jose_preferred? ? OperatorSignature.deliverable(dpp, representation_document) : nil
    return render_dpp(representation_document) if compact.nil?

    render plain: compact, content_type: OperatorSignature::MEDIA_TYPE
  end

  # The answer of ReadDPPVersionByIdAndDate: the signature kept for the
  # version read, where its payload is exactly the JSON the same request gets,
  # and that JSON otherwise. The state says whether such a signature exists:
  # signed or none.
  def render_version_or_signature(result)
    vary_on_accept!
    document = DppRepresentation.passport(result.document, representation)
    compact = OperatorSignature.deliverable_compact(result.signature, document)
    response.set_header(SIGNATURE_STATE_HEADER, compact ? OperatorSignature::SIGNED : OperatorSignature::NONE)
    return render_dpp(document) unless compact && jose_preferred?

    render plain: compact, content_type: OperatorSignature::MEDIA_TYPE
  end

  private

  def vary_on_accept!
    current = response.get_header("Vary").to_s.split(",").map(&:strip).reject(&:empty?)
    response.set_header("Vary", (current | ["Accept"]).join(", "))
  end

  # RFC 9110 12.5.1: for each media type the quality of the most specific
  # range that matches it. JOSE is chosen only with a real lead over JSON: on a
  # tie, without Accept or with "*/*" alone, the answer stays JSON.
  def jose_preferred?
    ranges = parse_accept(request.headers["Accept"])
    return false if ranges.empty?

    jose = quality(ranges, OperatorSignature::MEDIA_TYPE)
    jose.positive? && jose > quality(ranges, "application/json")
  end

  def parse_accept(accept)
    accept.to_s.split(",").filter_map do |part|
      type, *params = part.strip.split(";").map(&:strip)
      next if type.to_s.empty?

      q = params.find { |param| param.downcase.start_with?("q=") }
      [type.downcase, q ? q[2..].to_f.clamp(0.0, 1.0) : 1.0]
    end
  end

  def quality(ranges, media_type)
    major = media_type.split("/").first
    [media_type, "#{major}/*", "*/*"].each do |candidate|
      hit = ranges.find { |type, _| type == candidate }
      return hit.last if hit
    end
    0.0
  end
end
