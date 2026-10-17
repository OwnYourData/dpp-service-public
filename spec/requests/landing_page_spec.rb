# frozen_string_literal: true

require "rails_helper"

# The root of the hosted instance is a static page (public/index.html) that
# points visitors to the API documentation, the tools and the source code.
# Rails serves it through ActionDispatch::Static; no route is involved.
RSpec.describe "Landing page", type: :request do
  it "serves the start page at /" do
    get "/"

    expect(response).to have_http_status(:ok)
    expect(response.media_type).to eq("text/html")
    # A static file arrives as raw bytes (ASCII-8BIT); the page declares UTF-8
    # in its <meta charset>, so read it that way before comparing text.
    body = response.body.dup.force_encoding(Encoding::UTF_8)
    expect(body).to be_valid_encoding
    expect(body).to include("<title>DPP Service · OwnYourData</title>")
  end

  it "links to the API documentation that exists" do
    get "/"

    expect(response.body).to include('href="/api-docs/index.html"')
  end

  it "points to the DPP Linter and its source" do
    get "/"

    expect(response.body).to include('href="https://dpplint.ownyourdata.eu"')
    expect(response.body).to include('href="https://github.com/OwnYourData/dpplint"')
  end

  it "points to the validator results, its criteria and its source" do
    get "/"

    body = response.body.dup.force_encoding(Encoding::UTF_8)
    expect(body).to include('href="https://ownyourdata.github.io/dpp-validator/"')
    expect(body).to include('href="https://github.com/OwnYourData/dpp-criteria"')
    expect(body).to include('href="https://github.com/OwnYourData/dpp-validator"')
    expect(body).not_to include("In progress")
  end

  it "tells other operators how to add their service to the daily checks" do
    get "/"

    body = response.body.dup.force_encoding(Encoding::UTF_8)
    expect(body).to include(
      '<a href="https://github.com/OwnYourData/dpp-criteria/blob/main/services/README.md">' \
      "How to add your DPP service to the daily checks</a>"
    )
  end

  # Results change every day: the page links to them and never states a count
  # or calls a service conformant, compliant or certified.
  it "states no result of its own" do
    get "/"

    body = response.body.dup.force_encoding(Encoding::UTF_8)
    expect(body).not_to match(/\d+ of \d+/)
    expect(body).not_to match(/conformant|compliant|certified/i)
  end

  it "shows the OwnYourData mark beside the title and uses it as the icon" do
    get "/"

    expect(response.body).to include('<link rel="icon" href="/oyd-mark.svg" type="image/svg+xml">')
    expect(response.body).to include('<img class="mark" src="/oyd-mark.svg" alt=""')

    get "/oyd-mark.svg"

    expect(response).to have_http_status(:ok)
    expect(response.media_type).to eq("image/svg+xml")
  end

  it "names the funding of PACE-DPP once, in the footer" do
    get "/"

    body = response.body.dup.force_encoding(Encoding::UTF_8)
    expect(body.scan("917177").size).to eq(1)
    expect(body[body.index("<footer>")..]).to include(FundingNotice.html)
  end

  it "leaves the API untouched" do
    get "/up"

    expect(response).to have_http_status(:ok)
    expect(response.media_type).to eq("application/json")
  end
end
