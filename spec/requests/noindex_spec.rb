# frozen_string_literal: true

require "rails_helper"

# DPP_NOINDEX keeps an instance that is not for the public out of search
# engines (lib/noindex.rb).
RSpec.describe "Noindex", type: :request do
  def with_noindex(value)
    previous = ENV.fetch("DPP_NOINDEX", nil)
    value.nil? ? ENV.delete("DPP_NOINDEX") : ENV["DPP_NOINDEX"] = value
    yield
  ensure
    previous.nil? ? ENV.delete("DPP_NOINDEX") : ENV["DPP_NOINDEX"] = previous
  end

  context "when switched on" do
    around { |example| with_noindex("true") { example.run } }

    it "disallows everything in robots.txt" do
      get "/robots.txt"

      expect(response).to have_http_status(:ok)
      expect(response.media_type).to eq("text/plain")
      expect(response.body).to eq("User-agent: *\nDisallow: /\n")
      expect(response.headers["X-Robots-Tag"]).to eq("noindex, nofollow")
    end

    it "answers HEAD for robots.txt without a body" do
      head "/robots.txt"

      expect(response).to have_http_status(:ok)
      expect(response.body).to be_empty
    end

    it "puts X-Robots-Tag on pages, the API and errors" do
      ["/", "/up", "/dpp/v1/dpps/did%3Aoyd%3AzQmUnknown"].each do |path|
        get path, headers: { "X-Forwarded-Proto" => "https" }

        expect(response.headers["X-Robots-Tag"]).to eq("noindex, nofollow"), path
      end
    end

    it "takes 1 as well" do
      with_noindex("1") do
        get "/robots.txt"
        expect(response).to have_http_status(:ok)
      end
    end
  end

  context "when not set" do
    around { |example| with_noindex(nil) { example.run } }

    it "neither answers robots.txt nor sets the header" do
      get "/robots.txt"
      expect(response).to have_http_status(:not_found)
      expect(response.headers).not_to have_key("X-Robots-Tag")

      get "/"
      expect(response.headers).not_to have_key("X-Robots-Tag")
    end

    it "treats other values as off" do
      with_noindex("yes") do
        get "/robots.txt"
        expect(response).to have_http_status(:not_found)
      end
    end
  end
end
