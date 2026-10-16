# frozen_string_literal: true

require "json"
require "securerandom"
require "time"

# Refuses requests to the DPP API that reached the proxy in front of this
# service over HTTP/1.0 or HTTP/1.1.
#
# EN 18216:2026 clause 4 makes HTTP/2 the minimum version for DPP data exchange
# and rules out older ones. TLS ends at the proxy, so only the proxy knows which
# version the client spoke; it passes that on in the request header
# X-Client-Protocol (nginx: proxy_set_header X-Client-Protocol $server_protocol).
#
# The gate covers the API paths below /dpp/v1 on HTTPS only. The start page,
# /api-docs, /.well-known/dpp-service and /up stay open to every client, and so
# does plain HTTP, which the proxy redirects to HTTPS anyway. Without the header
# -- local development, tests, probes that go straight to the pod -- nothing is
# refused.
#
# The answer is 400 with the EN 18222 result object: EN 18222 Table 15 has no
# generic status for an unsupported HTTP version, and a faulty request must not
# be answered with a server error.
class HttpVersionGate
  HEADER      = "HTTP_X_CLIENT_PROTOCOL"
  API_PREFIX  = "/dpp/v1"
  ACCEPTED    = %r{\AHTTP/[2-9]}
  MESSAGE     = "HTTP/2 or higher is required for this API (EN 18216:2026 clause 4); " \
                "the request used %s."

  def initialize(app)
    @app = app
  end

  def call(env)
    return @app.call(env) unless refuse?(env)

    body = JSON.generate(
      statusCode: "ClientErrorBadRequest",
      message: [{
        messageType: "Error",
        text: format(MESSAGE, env[HEADER]),
        code: "http_version_not_supported",
        correlationId: env["action_dispatch.request_id"] || SecureRandom.uuid,
        timestamp: Time.now.utc.iso8601
      }]
    )
    [400, { "content-type" => "application/json; charset=utf-8",
            "content-length" => body.bytesize.to_s }, [body]]
  end

  private

  def refuse?(env)
    protocol = env[HEADER].to_s
    return false if protocol.empty? || protocol.match?(ACCEPTED)
    return false unless env["HTTP_X_FORWARDED_PROTO"] == "https"

    path = env["PATH_INFO"].to_s
    path == API_PREFIX || path.start_with?("#{API_PREFIX}/")
  end
end
