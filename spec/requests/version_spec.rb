# frozen_string_literal: true

require "rails_helper"

# GET /version (BuildInfo): the image tag and the commit this instance was
# built from, open to every client like /up, so a deploy check reads the
# running state without access to the cluster.
RSpec.describe "GET /version", type: :request do
  before { allow(ENV).to receive(:fetch).and_call_original }

  def with_build(tag, commit)
    allow(ENV).to receive(:fetch).with("DPP_IMAGE_TAG", "").and_return(tag)
    allow(ENV).to receive(:fetch).with("DPP_COMMIT", "").and_return(commit)
  end

  it "names the image tag and the commit, without a token" do
    with_build("261023a", "3f2ebf0b1c2d3e4f5a6b7c8d9e0f1a2b3c4d5e6f")

    get "/version"

    expect(response).to have_http_status(:ok)
    expect(response.media_type).to eq("application/json")
    expect(response.parsed_body).to eq("service" => "dpp-service", "imageTag" => "261023a",
                                       "commit" => "3f2ebf0b1c2d3e4f5a6b7c8d9e0f1a2b3c4d5e6f")
  end

  it "answers null for what a build did not hand in, rather than a guess" do
    with_build("", " ")

    get "/version"

    expect(response.parsed_body).to eq("service" => "dpp-service", "imageTag" => nil, "commit" => nil)
  end

  it "stays open below the HTTP version gate, like /up" do
    get "/version", headers: { "X-Client-Protocol" => "HTTP/1.1", "X-Forwarded-Proto" => "https" }

    expect(response).to have_http_status(:ok)
  end
end
