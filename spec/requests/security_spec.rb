# frozen_string_literal: true

require "rails_helper"

# What a public API needs around its methods: who may call it from a browser,
# how often anybody may call it, and what stays out of the log.
RSpec.describe "Protection around the API", type: :request do
  let(:dpp_document) do
    {
      "digitalProductPassportId" => "https://dpp.lumina.example/01/09520123456788/8546",
      "uniqueProductIdentifier" => "https://id.lumina.example/01/09520123456788",
      "granularity" => "model",
      "dppSchemaVersion" => "EN 18223:2026",
      "economicOperatorId" => "did:oyd:zQmPPwHJK1NHBz3BS89StWsfrH4pzkyqwJiK94zVj25wXUS"
    }
  end

  describe "cross-origin access" do
    it "lets any web page read" do
      get "/dpp/v1/dpps/#{CGI.escape('urn:unknown')}", headers: { "Origin" => "https://viewer.example" }

      expect(response.headers["Access-Control-Allow-Origin"]).to eq("*")
    end

    it "lets any web page ask for the passports of a set of products, which is a read" do
      options "/dpp/v1/dppsByProductIds",
              headers: { "Origin" => "https://viewer.example", "Access-Control-Request-Method" => "POST" }

      expect(response.headers["Access-Control-Allow-Origin"]).to eq("*")
    end

    it "does not let an unlisted web page write" do
      options "/dpp/v1/dpps",
              headers: { "Origin" => "https://somewhere.example", "Access-Control-Request-Method" => "POST" }

      expect(response.headers["Access-Control-Allow-Origin"]).to be_nil
    end
  end

  describe "rate limit" do
    include ActiveSupport::Testing::TimeHelpers

    # One window throughout, wherever in the minute the example happens to run.
    around { |example| travel_to(Time.utc(2026, 10, 24, 12, 0, 5)) { example.run } }

    it "answers 429 with Retry-After once a client has written too often in a minute" do
      ApplicationController::WRITE_LIMIT.times do
        post "/dpp/v1/dpps", params: dpp_document.to_json, headers: { "Content-Type" => "application/json" }
        expect(response).to have_http_status(:unauthorized)
      end

      post "/dpp/v1/dpps", params: dpp_document.to_json, headers: { "Content-Type" => "application/json" }

      expect(response).to have_http_status(:too_many_requests)
      expect(response.headers["Retry-After"]).to eq("60")
    end

    it "counts reads apart from writes" do
      ApplicationController::WRITE_LIMIT.times do
        post "/dpp/v1/dpps", params: dpp_document.to_json, headers: { "Content-Type" => "application/json" }
      end

      get "/dpp/v1/dpps/#{CGI.escape('urn:unknown')}"
      expect(response).to have_http_status(:not_found)

      post "/dpp/v1/dppsByProductIds", params: ["https://id.lumina.example/01/09520123456788"].to_json,
                                       headers: { "Content-Type" => "application/json" }
      expect(response).to have_http_status(:ok)
    end

    it "counts the requests other replicas have seen, since the count is kept in the shared database" do
      ApplicationController::READ_LIMIT.times { RateCounter.hit!("127.0.0.1:read", within: 60) }

      get "/dpp/v1/dpps/#{CGI.escape('urn:unknown')}"

      expect(response).to have_http_status(:too_many_requests)
    end

    it "counts all operations of a kind together, and starts again in the next minute" do
      half = ApplicationController::READ_LIMIT / 2
      half.times { get "/dpp/v1/dpps/#{CGI.escape('urn:unknown')}" }
      (ApplicationController::READ_LIMIT - half).times do
        post "/dpp/v1/dppsByProductIds", params: ["https://id.lumina.example/01/1"].to_json,
                                         headers: { "Content-Type" => "application/json" }
      end
      get "/dpp/v1/dpps/#{CGI.escape('urn:unknown')}/collections/X"
      expect(response).to have_http_status(:too_many_requests)

      travel 60.seconds
      get "/dpp/v1/dpps/#{CGI.escape('urn:unknown')}"
      expect(response).to have_http_status(:not_found)
    end

    it "lets a request through when the count cannot be kept" do
      allow(RateCounter).to receive(:upsert).and_raise(ActiveRecord::StatementInvalid, "database gone")

      expect(RateCounter.hit!("127.0.0.1:read", within: 60)).to eq(0)
    end

    it "keeps one row per address, kind and minute, and prunes those of past minutes" do
      RateCounter.hit!("192.0.2.1:read", within: 60)
      RateCounter.hit!("192.0.2.1:read", within: 60)
      expect(RateCounter.hit!("192.0.2.1:read", within: 60)).to eq(3)

      travel 120.seconds
      RateCounter.prune!

      expect(RateCounter.where("bucket LIKE ?", "192.0.2.1:%")).to be_empty
    end
  end

  describe "WWW-Authenticate (RFC 9110 15.5.2)" do
    it "names the bearer scheme on a 401 without a token, with no error" do
      post "/dpp/v1/dpps", params: dpp_document.to_json, headers: { "Content-Type" => "application/json" }

      expect(response).to have_http_status(:unauthorized)
      expect(response.headers["WWW-Authenticate"]).to eq("Bearer")
    end

    it "is readable from a browser, as are the headers that say what a read or a write applied" do
      get "/dpp/v1/dpps/#{CGI.escape('urn:unknown')}", headers: { "Origin" => "https://viewer.example" }

      exposed = response.headers["Access-Control-Expose-Headers"].split(/,\s*/)
      expect(exposed).to include("WWW-Authenticate", "X-DPP-Access-Roles", "X-DPP-Controlled-Part",
                                 "X-DPP-Signature-State", "X-DPP-Request-Binding", "X-DPP-Carrier")
    end

    it "is not sent with answers other than 401" do
      get "/dpp/v1/dpps/#{CGI.escape('urn:unknown')}"

      expect(response).to have_http_status(:not_found)
      expect(response.headers["WWW-Authenticate"]).to be_nil
    end
  end

  describe "the log" do
    let(:filter) { ActiveSupport::ParameterFilter.new(Rails.application.config.filter_parameters) }

    it "keeps keys, tokens and mandates out" do
      filtered = filter.filter("doc_key" => "a", "rev_key" => "b", "rev_log" => "c",
                               "access_token" => "d", "delegation" => "e")

      expect(filtered.values).to all(eq("[FILTERED]"))
    end

    it "leaves the passport's own attributes readable" do
      filtered = filter.filter(dpp_document)

      expect(filtered).to eq(dpp_document)
    end
  end
end
