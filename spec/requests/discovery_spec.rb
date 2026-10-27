# frozen_string_literal: true

require "rails_helper"

# docs/Delegation.md §6. The endpoint exists so an economic operator can look up
# the DID to name in the `sub` of their delegation, rather than being told it
# out of band.
RSpec.describe "GET /.well-known/dpp-service", type: :request do
  it "answers with the service DID and the audience" do
    allow(ServiceDid).to receive(:configured?).and_return(true)
    allow(ServiceDid).to receive(:discovery_document)
      .and_return("did" => "did:oyd:zQmService", "audience" => "https://dpp-service.example")

    get "/.well-known/dpp-service"

    expect(response).to have_http_status(:ok)
    expect(response.parsed_body)
      .to eq("did" => "did:oyd:zQmService", "audience" => "https://dpp-service.example")
  end

  it "needs no token — it is discovery, like the read paths" do
    allow(ServiceDid).to receive(:configured?).and_return(true)
    allow(ServiceDid).to receive(:discovery_document).and_return("did" => "did:oyd:zQmService")

    get "/.well-known/dpp-service"

    expect(response).to have_http_status(:ok)
  end

  it "says so plainly when this deployment has no service DID" do
    allow(ServiceDid).to receive(:configured?).and_return(false)

    get "/.well-known/dpp-service"

    expect(response).to have_http_status(:not_found)
    expect(response.parsed_body["error"]).to match(/no service DID/)
  end

  it "never exposes key material" do
    allow(ServiceDid).to receive(:configured?).and_return(true)
    allow(ServiceDid).to receive(:discovery_document)
      .and_return("did" => "did:oyd:zQmService", "audience" => "https://dpp-service.example")

    get "/.well-known/dpp-service"

    expect(response.body).not_to match(/z1S5/)
    expect(response.parsed_body.keys).to contain_exactly("did", "audience")
  end

  describe "the reader DIDs" do
    let(:service_did) { "did:oyd:zQmService" }
    let(:readers) do
      [ReaderDid.new(name: "STAGING", pod: "https://dpp-staging.go-data.at",
                     did: "did:oyd:zQmReaderStaging", doc_key: "z1S5secretStaging"),
       ReaderDid.new(name: "PRODUCTION", pod: "https://dpp.go-data.at",
                     did: "did:oyd:zQmReaderProduction", doc_key: "z1S5secretProduction")]
    end

    before do
      allow(ServiceDid).to receive(:configured?).and_return(true)
      allow(ServiceDid).to receive(:discovery_document)
        .and_return("did" => service_did, "audience" => "https://dpp-service.example")
    end

    it "lists one reader per pod beside the unchanged service DID" do
      allow(ReaderDid).to receive(:all).and_return(readers)

      get "/.well-known/dpp-service"

      expect(response.parsed_body).to eq(
        "did" => service_did, "audience" => "https://dpp-service.example",
        "readers" => [{ "pod" => "https://dpp-staging.go-data.at", "did" => "did:oyd:zQmReaderStaging" },
                      { "pod" => "https://dpp.go-data.at", "did" => "did:oyd:zQmReaderProduction" }]
      )
    end

    it "never lists the service DID as a reader" do
      allow(ReaderDid).to receive(:all).and_return(readers)

      get "/.well-known/dpp-service"

      expect(response.parsed_body["readers"].map { |r| r["did"] }).not_to include(service_did)
    end

    it "lets a pod find exactly one entry" do
      allow(ReaderDid).to receive(:all).and_return(readers)

      get "/.well-known/dpp-service"

      pods = response.parsed_body["readers"].map { |r| r["pod"] }
      expect(pods).to eq(pods.uniq)
    end

    it "carries no key material of a reader" do
      allow(ReaderDid).to receive(:all).and_return(readers)

      get "/.well-known/dpp-service"

      expect(response.body).not_to include("z1S5")
      expect(response.parsed_body["readers"].flat_map(&:keys).uniq).to contain_exactly("pod", "did")
    end

    it "leaves the member out when no reader is configured" do
      allow(ReaderDid).to receive(:all).and_return([])

      get "/.well-known/dpp-service"

      expect(response.parsed_body).not_to have_key("readers")
    end

    it "leaves the member out when the configuration is refused" do
      allow(ReaderDid).to receive(:all).and_raise(ReaderDid::ConfigError.new(["broken"]))

      get "/.well-known/dpp-service"

      expect(response).to have_http_status(:ok)
      expect(response.parsed_body).not_to have_key("readers")
    end
  end
  describe "the authority issuers" do
    before do
      allow(ServiceDid).to receive(:configured?).and_return(true)
      allow(ServiceDid).to receive(:discovery_document).and_return("did" => "did:oyd:zQmService")
      allow(ReaderDid).to receive(:discovery_entries).and_return(nil)
    end

    it "lists them when they are configured" do
      allow(AuthorityIssuers).to receive(:all).and_return(["did:oyd:zQmIssuer"])

      get "/.well-known/dpp-service"

      expect(response.parsed_body["authorityIssuers"]).to eq(["did:oyd:zQmIssuer"])
    end

    it "leaves the member out without them" do
      allow(AuthorityIssuers).to receive(:all).and_return([])

      get "/.well-known/dpp-service"

      expect(response.parsed_body).not_to have_key("authorityIssuers")
    end
  end

  describe "the carrier hosts" do
    before do
      allow(ServiceDid).to receive(:configured?).and_return(true)
      allow(ServiceDid).to receive(:discovery_document).and_return("did" => "did:oyd:zQmService")
      allow(ReaderDid).to receive(:discovery_entries).and_return(nil)
    end

    it "lists the hosts on which this service answers product identifiers" do
      allow(CarrierHosts).to receive(:list).and_return(["id.example.org"])

      get "/.well-known/dpp-service"

      expect(response.parsed_body["carrierHosts"]).to eq(["id.example.org"])
    end

    it "leaves the member out without them" do
      allow(CarrierHosts).to receive(:list).and_return([])

      get "/.well-known/dpp-service"

      expect(response.parsed_body).not_to have_key("carrierHosts")
    end
  end
end
