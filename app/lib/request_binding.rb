# frozen_string_literal: true

require "digest"
require "base64"
require "date"

# Binds a self-issued bearer token to the one request it was made for
# (docs/Integrity.md section 11). The token of every write carries
#
#   rqh = base64url(SHA-256(METHOD LF TARGET LF base64url(SHA-256(BODY))))
#
# without padding, the way DPoP forms "ath":
#
#   METHOD  the request method in capitals
#   TARGET  the request-target exactly as in the request line: the path with
#           the query where there is one, percent-encoding untouched
#           (RFC 9112 3.2.1). Scheme and host are not part of it; "aud"
#           already names the service.
#   BODY    the bytes of the request body as sent, without any
#           canonicalisation; an empty body is the empty octet string.
#   LF      a single "\n"
#
# A token with such a claim is the economic operator's signed statement that
# it asked for exactly this change. Bytes rather than canonical JSON: every
# client can compute it without a JSON canonicalisation library, and they are
# what the service receives.
#
# Until REQUIRED_FROM a write without the claim is still accepted, with the
# header below and recorded as unbound in the write log; from then on it is
# refused.
module RequestBinding
  CLAIM  = "rqh"
  HEADER = "X-DPP-Request-Binding"

  module_function

  # The first day on which a write without the claim is refused.
  def required_from
    Date.iso8601(ENV.fetch("DPP_REQUEST_BINDING_FROM", "2026-12-01"))
  end

  def required?(today: Time.now.utc.to_date) = today >= required_from

  def body_digest(body) = b64(Digest::SHA256.digest(body.to_s.b))

  def digest(method, target, body)
    b64(Digest::SHA256.digest([method.to_s.upcase, target.to_s, body_digest(body)].join("\n").b))
  end

  def b64(bytes) = Base64.urlsafe_encode64(bytes, padding: false)
end
