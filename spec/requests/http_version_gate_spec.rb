# frozen_string_literal: true

require "rails_helper"

# The proxy in front of the service reports the client's HTTP version in
# X-Client-Protocol; HTTP/1.x is refused on the DPP API (EN 18216:2026 clause 4).
RSpec.describe "HTTP version gate", type: :request do
  let(:api_path) { "/dpp/v1/dpps/did%3Aoyd%3AzQmUnknown" }

  def headers_for(protocol)
    { "X-Client-Protocol" => protocol, "X-Forwarded-Proto" => "https" }
  end

  %w[HTTP/1.0 HTTP/1.1].each do |protocol|
    it "refuses #{protocol} on the API with 400 and the EN 18222 result object" do
      get api_path, headers: headers_for(protocol)

      expect(response).to have_http_status(:bad_request)
      body = JSON.parse(response.body)
      expect(body["statusCode"]).to eq("ClientErrorBadRequest")
      expect(body["message"].first).to include("messageType" => "Error", "code" => "http_version_not_supported")
      expect(body["message"].first["text"]).to include("HTTP/2", protocol)
    end
  end

  it "refuses HTTP/1.1 on writes as well" do
    post "/dpp/v1/dpps", params: "{}", headers: headers_for("HTTP/1.1").merge("Content-Type" => "application/json")

    expect(response).to have_http_status(:bad_request)
    expect(JSON.parse(response.body).dig("message", 0, "code")).to eq("http_version_not_supported")
  end

  %w[HTTP/2.0 HTTP/3.0].each do |protocol|
    it "lets #{protocol} through to the API" do
      get api_path, headers: headers_for(protocol)

      expect(response).to have_http_status(:not_found)
    end
  end

  it "lets requests without the header through (no proxy, tests, probes)" do
    get api_path, headers: { "X-Forwarded-Proto" => "https" }

    expect(response).to have_http_status(:not_found)
  end

  it "leaves plain HTTP to the proxy's redirect" do
    get api_path, headers: { "X-Client-Protocol" => "HTTP/1.1", "X-Forwarded-Proto" => "http" }

    expect(response).not_to have_http_status(:bad_request)
  end

  ["/", "/up", "/.well-known/dpp-service", "/dpp/v10"].each do |path|
    it "does not apply to #{path}" do
      get path, headers: headers_for("HTTP/1.1")

      expect(response).not_to have_http_status(:bad_request)
    end
  end
end
