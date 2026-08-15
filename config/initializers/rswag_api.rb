# frozen_string_literal: true

Rswag::Api.configure do |c|
  # Serve OpenAPI documents from the repository's docs/ folder.
  c.openapi_root = Rails.root.join("docs").to_s
end
