# frozen_string_literal: true

require "rails_helper"

# EN 18216:2026 clause 4: HTTP/2 is the minimum for DPP data exchange. The
# outbound calls go through httpx, which negotiates it; these specs pin down the
# small interface the callers rely on and how httpx failures are reported.
RSpec.describe OutboundHttp do
  let(:session) { instance_double(HTTPX::Session) }

  before { allow(HTTPX).to receive(:with).and_return(session) }

  def httpx_response(status:, body:, version: "2.0")
    instance_double(HTTPX::Response, status: status, to_s: body, version: version)
  end

  # A real ErrorResponse, as httpx hands one back instead of raising.
  def httpx_failure(error)
    HTTPX::ErrorResponse.new(HTTPX::Request.new("GET", "https://dpp.go-data.at/x", HTTPX::Options.new), error)
  end

  it "sends method, URL, headers and body, and returns status, body and HTTP version" do
    allow(session).to receive(:request)
      .with("POST", "https://dpp.go-data.at/oauth/token",
            headers: { "DPoP" => "proof" }, body: "a=1")
      .and_return(httpx_response(status: 200, body: "{}"))

    response = described_class.request(:post, "https://dpp.go-data.at/oauth/token",
                                       headers: { "DPoP" => "proof" }, body: "a=1",
                                       open_timeout: 5, read_timeout: 15)

    expect(response.code).to eq("200")
    expect(response.body).to eq("{}")
    expect(response.message).to eq("OK")
    expect(response.version).to eq("2.0")
  end

  it "passes the timeouts on to httpx" do
    allow(session).to receive(:request).and_return(httpx_response(status: 204, body: ""))

    described_class.request(:get, "https://dpp.go-data.at/x", open_timeout: 5, read_timeout: 15)

    expect(HTTPX).to have_received(:with)
      .with(timeout: { connect_timeout: 5, read_timeout: 15, request_timeout: 20 })
  end

  it "reports a timeout as TimeoutError" do
    error = HTTPX::ConnectTimeoutError.new(5, "timed out while waiting on select")
    allow(session).to receive(:request).and_return(httpx_failure(error))

    expect { described_class.request(:get, "https://dpp.go-data.at/x", open_timeout: 5, read_timeout: 15) }
      .to raise_error(OutboundHttp::TimeoutError)
  end

  it "reports any other failure as ConnectionError, naming its cause" do
    error = HTTPX::ResolveError.new("Can't resolve dpp.example")
    allow(session).to receive(:request).and_return(httpx_failure(error))

    expect { described_class.request(:get, "https://dpp.example/x", open_timeout: 5, read_timeout: 15) }
      .to raise_error(OutboundHttp::ConnectionError, /ResolveError/)
  end

  describe OutboundHttp::Request do
    subject(:req) do
      described_class.new(method: :get, url: "https://dpp.go-data.at/dpp/v1/x?date=1",
                          headers: { "Authorization" => "DPoP t" }, body: nil)
    end

    it "gives the path with the query, as the request line carries it" do
      expect(req.path).to eq("/dpp/v1/x?date=1")
    end

    it "reads headers regardless of case" do
      expect(req["authorization"]).to eq("DPoP t")
      expect(req["DPoP"]).to be_nil
    end
  end
end
