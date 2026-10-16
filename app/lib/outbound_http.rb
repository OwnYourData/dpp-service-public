# frozen_string_literal: true

require "httpx"
require "uri"

# Outbound HTTPS of the service: the calls to a custodian's hosting pod
# (PodStorage) and the read-back of a delivered passport (PayloadCommitment).
#
# EN 18216:2026 clause 4 makes HTTP/2 the minimum version for DPP data exchange
# and rules out older ones. Ruby's Net::HTTP speaks HTTP/1.1 only, so these
# calls go through httpx, which negotiates HTTP/2 via ALPN. A server that offers
# nothing but HTTP/1.1 is still answered; which version was used is on the
# response.
#
# The interface is deliberately small -- one request in, status and body out --
# so that callers keep their own error mapping and the specs can replace
# +perform+ without a network.
module OutboundHttp
  # What was sent. #path and #[] read like the request objects of Net::HTTP,
  # which is what callers and specs inspect.
  Request = Struct.new(:method, :url, :headers, :body, keyword_init: true) do
    def path
      URI.parse(url).request_uri
    end

    def [](name)
      headers.find { |key, _| key.to_s.casecmp?(name.to_s) }&.last
    end
  end

  # What came back. +code+ is a string, as with Net::HTTP.
  Response = Struct.new(:code, :body, :message, :version, keyword_init: true)

  class TimeoutError < StandardError; end
  class ConnectionError < StandardError; end

  module_function

  def request(method, url, headers: {}, body: nil, open_timeout:, read_timeout:)
    perform(Request.new(method: method, url: url.to_s, headers: headers, body: body),
            open_timeout: open_timeout, read_timeout: read_timeout)
  end

  # One session per call: the calls are rare and go to different custodians,
  # so a shared pool would buy little and outlive a custodian's certificate or
  # address change.
  def perform(req, open_timeout:, read_timeout:)
    session = HTTPX.with(timeout: { connect_timeout: open_timeout,
                                    read_timeout: read_timeout,
                                    request_timeout: open_timeout + read_timeout })
    res = session.request(req.method.to_s.upcase, req.url, headers: req.headers, body: req.body)

    if res.is_a?(HTTPX::ErrorResponse)
      raise TimeoutError, res.error.message if res.error.is_a?(HTTPX::TimeoutError)

      raise ConnectionError, "#{res.error.class}: #{res.error.message}"
    end

    Response.new(code: res.status.to_s,
                 body: res.to_s,
                 message: Rack::Utils::HTTP_STATUS_CODES.fetch(res.status, ""),
                 version: res.version)
  end
end
