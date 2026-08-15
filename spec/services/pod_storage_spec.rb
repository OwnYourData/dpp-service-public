# frozen_string_literal: true

require "rails_helper"

# HTTP-Schicht des Pod-Clients. Net::HTTP ist gestubbt, damit die Specs ohne
# Netz laufen; geprüft wird, welche Requests der Client baut und wie er
# Antworten des Pods auf die generischen Statuscodes aus prEN 18222 (Tabelle 16)
# abbildet.
RSpec.describe PodStorage do
  let(:base_url) { "https://dpp.go-data.at" }
  let(:config) do
    { base_url: base_url, collection_id: "1", client_id: "cid", client_secret: "csec" }
  end

  subject(:storage) { described_class.new(**config) }

  before { described_class.reset_token_cache! }

  # Fängt Net::HTTP ab und protokolliert die abgesetzten Requests.
  def stub_pod(responses)
    requests = []
    queue = Array(responses).dup

    http = double("http")
    allow(http).to receive(:request) do |req|
      requests << req
      spec = queue.size > 1 ? queue.shift : queue.first
      body = spec[:body].is_a?(String) ? spec[:body] : JSON.generate(spec[:body] || {})
      instance_double(Net::HTTPResponse, code: spec[:status].to_s, body: body, message: "stubbed")
    end
    allow(Net::HTTP).to receive(:start) { |*_args, &blk| blk.call(http) }
    requests
  end

  def token_response(expires_in: 7200)
    { status: 200, body: { access_token: "pod-token", expires_in: expires_in } }
  end

  describe "validation of the storage token" do
    it "derives the base_url limit from the Registry's 50-character rule" do
      expect(described_class::MAX_BASE_URL_LENGTH).to eq(50 - 3 - Dpp::SHORT_ID_LENGTH)
      expect(described_class::MAX_BASE_URL_LENGTH).to eq(35)
    end

    it "accepts a base_url that leaves room for the short link" do
      expect { described_class.new(**config) }.not_to raise_error
      expect("#{base_url}/p/#{'x' * Dpp::SHORT_ID_LENGTH}".length).to be <= 50
    end

    it "rejects a base_url that is too long" do
      expect { described_class.new(**config.merge(base_url: "https://#{'a' * 40}.example.org")) }
        .to raise_error(described_class::ConfigError, /50-character limit/)
    end

    it "rejects plain http (prEN 18216 §6.2 requires TLS)" do
      expect { described_class.new(**config.merge(base_url: "http://dpp.go-data.at")) }
        .to raise_error(described_class::ConfigError, /https/)
    end

    %i[base_url collection_id client_id client_secret].each do |field|
      it "rejects a token without #{field}" do
        expect { described_class.new(**config.merge(field => "")) }
          .to raise_error(described_class::ConfigError, /#{field}/)
      end
    end

    it "maps a configuration error to ClientErrorBadRequest" do
      error = described_class::ConfigError.new("nope")
      expect(error.status_code).to eq("ClientErrorBadRequest")
    end

    it "strips a trailing slash so paths do not double up" do
      expect(described_class.new(**config.merge(base_url: "#{base_url}/")).base_url).to eq(base_url)
    end
  end

  describe ".from_jwt" do
    it "reads the four OAuth2 parameters out of the token" do
      raw = JWT.encode(config, nil, "none")
      parsed = described_class.from_jwt(raw)

      expect(parsed.base_url).to eq(base_url)
      expect(parsed.collection_id).to eq("1")
      expect(parsed.client_id).to eq("cid")
      expect(JSON.parse(parsed.credentials_json)["client_secret"]).to eq("csec")
    end

    it "rejects a malformed token" do
      expect { described_class.from_jwt("not-a-jwt") }
        .to raise_error(described_class::ConfigError, /Invalid storage token/)
    end

    it "rejects a missing token" do
      expect { described_class.from_jwt(nil) }
        .to raise_error(described_class::ConfigError, /Missing storage token/)
    end
  end

  describe "#token" do
    it "requests a client_credentials token from the pod" do
      requests = stub_pod([token_response])

      expect(storage.token).to eq("pod-token")

      req = requests.first
      expect(req.path).to eq("/oauth/token")
      expect(req.body).to include("grant_type=client_credentials", "client_id=cid",
                                  "client_secret=csec", "scope=write")
    end

    it "caches the token instead of asking again on every call" do
      requests = stub_pod([token_response])

      3.times { storage.token }
      expect(requests.size).to eq(1)
    end

    it "does not cache a token that is about to expire" do
      requests = stub_pod([token_response(expires_in: 10)])

      storage.token
      storage.token
      expect(requests.size).to be >= 1 # kurzlebige Tokens werden nicht wiederverwendet
    end

    it "reports missing credentials as ClientNotAuthorized" do
      stub_pod([{ status: 200, body: {} }])

      expect { storage.token }
        .to raise_error(described_class::Error) { |e| expect(e.status_code).to eq("ClientNotAuthorized") }
    end
  end

  describe "#create_object" do
    let(:dpp) do
      Dpp.new(dpp_id: "did:oyd:zX", product_id: "https://id.example/01/1", short_id: "abc123DEF456",
              dpp_schema_version: "prEN 18223:2025", economic_operator_id: "did:web:e",
              last_update: Time.now.utc)
    end

    it "posts the card that pod-dpp looks the passport up by" do
      requests = stub_pod([token_response, { status: 200, body: { "object-id" => 4711 } }])

      expect(storage.create_object(dpp)).to eq("4711")

      card = JSON.parse(requests.last.body)
      expect(requests.last.path).to eq("/object")
      expect(card).to include(
        "collection-id"            => 1,          # numerisch, wie dc-pod es erwartet
        "type"                     => "DigitalProductPassport",
        "short_id"                 => "abc123DEF456",
        "DigitalProductPassportID" => "did:oyd:zX",
        "ProductID"                => "https://id.example/01/1"
      )
      expect(card).not_to have_key("schema") # sonst versucht dc-pod ein SOyA-Label
      expect(requests.last["Authorization"]).to eq("Bearer pod-token")
    end

    it "fails loudly when the pod returns no object-id" do
      stub_pod([token_response, { status: 200, body: {} }])

      expect { storage.create_object(dpp) }.to raise_error(described_class::Error, /object-id/)
    end
  end

  describe "#write_payload" do
    it "puts the DPP document to the write endpoint" do
      requests = stub_pod([token_response, { status: 200, body: {} }])

      storage.write_payload("4711", { "ProductID" => "https://id.example/01/1" })

      expect(requests.last.path).to eq("/object/4711/write")
      expect(JSON.parse(requests.last.body)).to eq("ProductID" => "https://id.example/01/1")
    end
  end

  describe "#version_at" do
    it "asks the pod's public path and needs no token" do
      requests = stub_pod([{ status: 200, body: { "DPPStatus" => "Active" } }])

      result = storage.version_at("https://id.example/01/1", Time.utc(2026, 8, 12, 12))

      expect(result).to eq("DPPStatus" => "Active")
      expect(requests.last.path).to start_with("/dpp/v1/dppsByProductIdAndDate/")
      expect(requests.last.path).to include(CGI.escape("2026-08-12T12:00:00Z"))
      expect(requests.last["Authorization"]).to be_nil
    end

    it "returns nil when the pod has no version for that date" do
      stub_pod([{ status: 404, body: { "error" => "DPP not found" } }])

      expect(storage.version_at("https://id.example/01/1", Time.utc(2020))).to be_nil
    end
  end

  describe "error mapping (prEN 18222 Table 16)" do
    {
      401 => "ClientNotAuthorized",
      403 => "ClientNotAuthorized",
      404 => "ClientErrorResourceNotFound",
      500 => "ServerErrorBadGateway",
      502 => "ServerErrorBadGateway"
    }.each do |http_status, generic|
      it "maps HTTP #{http_status} to #{generic}" do
        stub_pod([token_response, { status: http_status, body: { "error" => "boom" } }])

        expect { storage.read_payload("4711") }
          .to raise_error(described_class::Error) { |e| expect(e.status_code).to eq(generic) }
      end
    end

    it "drops the cached token when the pod rejects it" do
      stub_pod([token_response, { status: 401, body: {} }])

      expect { storage.read_payload("4711") }.to raise_error(described_class::Error)
      expect(described_class.token_cache_get([base_url, "cid"])).to be_nil
    end

    it "reports an unreachable pod as a bad gateway" do
      allow(Net::HTTP).to receive(:start).and_raise(Errno::ECONNREFUSED)

      expect { storage.token }
        .to raise_error(described_class::Error) { |e|
          expect(e.status_code).to eq("ServerErrorBadGateway")
          expect(e.message).to include("unreachable")
        }
    end

    it "reports a timeout as a bad gateway" do
      allow(Net::HTTP).to receive(:start).and_raise(Net::ReadTimeout)

      expect { storage.token }.to raise_error(described_class::Error, /timed out/)
    end
  end
end
