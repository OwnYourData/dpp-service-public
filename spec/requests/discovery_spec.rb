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
end
