# frozen_string_literal: true

require "rails_helper"

# The custodian's public read paths, as this service uses them. OutboundHttp is
# stubbed; what is checked is the request that goes out -- no token, no proof,
# the passport identifier as one encoded path segment -- and how the answers map
# onto the generic status codes of EN 18222:2026 (Table 15).
RSpec.describe PodStorage::PublicReader do
  let(:base_url) { "https://dpp.go-data.at" }
  let(:dpp_id)   { "did:oyd:zQmX" }
  let(:document) { { "digitalProductPassportId" => dpp_id, "elements" => [{ "elementId" => "E" }] } }

  subject(:reader) { described_class.new(base_url) }

  def stub_pod(status:, body: nil)
    requests = []
    allow(OutboundHttp).to receive(:perform) do |req, **|
      requests << req
      text = body.is_a?(String) ? body : JSON.generate(body || {})
      OutboundHttp::Response.new(code: status.to_s, body: text, message: "stubbed", version: "2.0")
    end
    requests
  end

  describe "#document" do
    it "reads the full representation over the public path, as JSON" do
      requests = stub_pod(status: 200, body: document)

      expect(reader.document(dpp_id)).to eq(document)

      req = requests.last
      expect(req.method).to eq(:get)
      expect(req.path).to eq("/dpp/v1/dpps/did%3Aoyd%3AzQmX?representation=full")
      expect(req["Accept"]).to eq("application/json")
    end

    it "sends no token and no proof" do
      requests = stub_pod(status: 200, body: document)

      reader.document(dpp_id)

      expect(requests.last["Authorization"]).to be_nil
      expect(requests.last["DPoP"]).to be_nil
    end

    it "needs no delegation and never asks the token endpoint" do
      requests = stub_pod(status: 200, body: document)

      described_class.new(base_url).document(dpp_id)

      expect(requests.map(&:path)).not_to include("/oauth/token")
    end

    # A shared cache in front of the custodian may still hold the state before
    # the last write; an update built on it would undo that write.
    it "asks caches on the way to revalidate" do
      requests = stub_pod(status: 200, body: document)

      reader.document(dpp_id)

      expect(requests.last["Cache-Control"]).to eq("no-cache")
    end

    it "carries the identifier as one percent-encoded path segment" do
      requests = stub_pod(status: 200, body: document)

      reader.document("did:oyd:zQmX@dpp.go-data.at/x y")

      expect(requests.last.path)
        .to start_with("/dpp/v1/dpps/did%3Aoyd%3AzQmX%40dpp.go-data.at%2Fx%20y?")
    end

    it "strips a trailing slash from the base URL" do
      requests = stub_pod(status: 200, body: document)

      described_class.new("#{base_url}/").document(dpp_id)

      expect(requests.last.url).to start_with("#{base_url}/dpp/v1/dpps/")
    end

    it "maps 404 to ClientErrorResourceNotFound" do
      stub_pod(status: 404, body: { "error" => "DPP not found" })

      expect { reader.document(dpp_id) }
        .to raise_error(PodStorage::Error) { |e| expect(e.status_code).to eq("ClientErrorResourceNotFound") }
    end

    [500, 502, 503].each do |status|
      it "maps #{status} to ServerErrorBadGateway" do
        stub_pod(status: status, body: { "error" => "boom" })

        expect { reader.document(dpp_id) }
          .to raise_error(PodStorage::Error) { |e| expect(e.status_code).to eq("ServerErrorBadGateway") }
      end
    end

    it "maps a refusal on a public path to ServerErrorBadGateway, not to the client's authorisation" do
      stub_pod(status: 401, body: { "error" => "invalid_token" })

      expect { reader.document(dpp_id) }
        .to raise_error(PodStorage::Error) { |e| expect(e.status_code).to eq("ServerErrorBadGateway") }
    end

    it "maps an unreachable custodian to ServerErrorBadGateway" do
      allow(OutboundHttp).to receive(:perform)
        .and_raise(OutboundHttp::ConnectionError, "Errno::ECONNREFUSED: Connection refused")

      expect { reader.document(dpp_id) }
        .to raise_error(PodStorage::Error) { |e| expect(e.status_code).to eq("ServerErrorBadGateway") }
    end

    it "maps a timeout to ServerErrorBadGateway" do
      allow(OutboundHttp).to receive(:perform).and_raise(OutboundHttp::TimeoutError, "read timeout")

      expect { reader.document(dpp_id) }
        .to raise_error(PodStorage::Error) { |e| expect(e.status_code).to eq("ServerErrorBadGateway") }
    end

    # Read as an empty passport, an HTML page would let the next update write
    # the passport back without its content.
    it "refuses an answer that is not JSON" do
      stub_pod(status: 200, body: "<!doctype html><title>DPP</title>")

      expect { reader.document(dpp_id) }
        .to raise_error(PodStorage::Error) { |e| expect(e.status_code).to eq("ServerErrorBadGateway") }
    end

    it "refuses JSON that is not an object" do
      stub_pod(status: 200, body: "[1,2]")

      expect { reader.document(dpp_id) }
        .to raise_error(PodStorage::Error) { |e| expect(e.status_code).to eq("ServerErrorBadGateway") }
    end
  end

  describe "#version_at" do
    it "asks the pod's public path and needs no token" do
      requests = stub_pod(status: 200, body: { "dppStatus" => "Active" })

      result = reader.version_at(dpp_id, Time.utc(2026, 8, 12, 12))

      expect(result).to eq("dppStatus" => "Active")
      expect(requests.last.path).to start_with("/dpp/v1/dppsByIdAndDate/did%3Aoyd%3AzQmX?")
      expect(requests.last.path).to include("date=2026-08-12T12%3A00%3A00Z")
      expect(requests.last.path).to include("representation=full")
      expect(requests.last["Authorization"]).to be_nil
      expect(requests.last["DPoP"]).to be_nil
    end

    it "returns nil when the pod has no version for that date" do
      stub_pod(status: 404, body: { "error" => "DPP not found" })

      expect(reader.version_at(dpp_id, Time.utc(2020))).to be_nil
    end

    it "does not hide a failing custodian behind nil" do
      stub_pod(status: 503)

      expect { reader.version_at(dpp_id, Time.utc(2020)) }
        .to raise_error(PodStorage::Error) { |e| expect(e.status_code).to eq("ServerErrorBadGateway") }
    end
  end

  it "refuses to be built without a base URL" do
    expect { described_class.new("") }.to raise_error(PodStorage::ConfigError)
  end
end
