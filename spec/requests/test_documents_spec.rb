# frozen_string_literal: true

require "rails_helper"

# The documents a test passport links to (public/test-documents/): reachable,
# with the media type the passport states, and unmistakably a test.
RSpec.describe "Test documents", type: :request do
  %w[declaration-of-conformity dismantling-instructions].each do |name|
    it "serves #{name} as HTML, marked as a test document" do
      get "/test-documents/test-sig-0002/#{name}.html"

      expect(response).to have_http_status(:ok)
      expect(response.media_type).to eq("text/html")
      expect(response.body).to include("<title>TEST DOCUMENT", "fictitious", "noindex",
                                       "https://id.ownyourdata.eu/01/09520123456788/21/TEST-SIG-0002")
      expect(response.body).not_to match(/<script|<link|src=/)
    end
  end
end
